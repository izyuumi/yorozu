//! Pure single-flight history synchronization and open-conversation model.
use crate::{
    events::{ConvList, Envelope, History, Message},
    model::{Conversation, Item},
    outbox,
};
use std::collections::VecDeque;
pub const REMOVED: &str = "This conversation was archived or deleted on another device.";
#[derive(Default)]
pub struct Machine {
    pub list: Vec<Conversation>,
    pub open: Option<Open>,
    online: bool,
    queue: VecDeque<Request>,
    flight: Option<Flight>,
    arrival: u64,
}
pub struct Open {
    pub conv_id: String,
    pub items: Vec<Item>,
    pub older_more: bool,
    pub typing_until: Option<u64>,
}
#[derive(Clone, Debug, PartialEq, Eq)]
enum Request {
    List,
    History {
        conv_id: String,
        before: Option<i64>,
    },
}
struct Flight {
    request: Request,
    arrival: u64,
    deadline: u64,
}
pub enum Event {
    SessionOpened,
    SessionLost,
    Open(Option<String>),
    New(String),
    Older(String),
    Outgoing(Message),
    Live(Envelope),
    Tick,
}
#[derive(Debug)]
pub enum Effect {
    Send(Envelope),
    Notice(&'static str),
    Listed,
    Page {
        conv_id: String,
        items: usize,
        more: bool,
        newest: bool,
    },
}
impl Machine {
    pub fn title(&self, conv: &Conversation) -> String {
        conv.title
            .clone()
            .or_else(|| {
                self.open
                    .as_ref()
                    .filter(|o| o.conv_id == conv.conv_id)
                    .and_then(|o| {
                        o.items
                            .iter()
                            .find(|i| i.kind == "user")
                            .and_then(|i| i.text.lines().next())
                            .map(str::to_owned)
                    })
            })
            .unwrap_or_else(|| "New conversation".into())
    }
    pub fn step(&mut self, event: Event, outbox: &outbox::Machine, now: u64) -> Vec<Effect> {
        let mut effects = vec![];
        match event {
            Event::SessionOpened => {
                self.online = true;
                self.queue.clear();
                self.flight = None;
                self.queue.push_back(Request::List);
                if let Some(o) = &self.open {
                    self.queue.push_back(Request::History {
                        conv_id: o.conv_id.clone(),
                        before: None,
                    });
                }
            }
            Event::SessionLost => {
                self.online = false;
                self.queue.clear();
                self.flight = None;
                if let Some(o) = &mut self.open {
                    o.typing_until = None;
                }
            }
            Event::Open(id) => {
                if self.open.as_ref().map(|o| &o.conv_id) == id.as_ref() {
                    return effects;
                }
                self.open = id.map(|conv_id| Open {
                    conv_id,
                    items: vec![],
                    older_more: false,
                    typing_until: None,
                });
                if let Some(o) = &mut self.open {
                    for row in outbox
                        .rows
                        .iter()
                        .filter(|r| r.message.conv_id == o.conv_id && r.mark.pending())
                    {
                        self.arrival += 1;
                        let mut item = Item::live(
                            "user",
                            &row.message.message_id,
                            &row.message.text,
                            now as i64,
                        );
                        item.arrival = self.arrival;
                        o.items.push(item);
                    }
                }
                // Discard requests for conversations whose items we no longer hold.
                self.queue.retain(|r| matches!(r, Request::List));
                if let Some(o) = &self.open {
                    if self.online {
                        self.queue.push_back(Request::History {
                            conv_id: o.conv_id.clone(),
                            before: None,
                        });
                    }
                }
            }
            Event::New(id) => {
                self.upsert(Conversation {
                    conv_id: id.clone(),
                    updated_at: now as i64,
                    title: None,
                    archived: false,
                    deleted: false,
                });
                effects.extend(self.step(Event::Open(Some(id)), outbox, now));
            }
            Event::Older(id) => {
                if let Some(o) = self
                    .open
                    .as_ref()
                    .filter(|o| o.conv_id == id && o.older_more)
                {
                    if let Some(before) = o.items.iter().filter_map(|i| i.seq).min() {
                        self.enqueue(Request::History {
                            conv_id: id,
                            before: Some(before),
                        });
                    }
                }
            }
            Event::Outgoing(message) => {
                if !self.list.iter().any(|c| c.conv_id == message.conv_id) {
                    self.upsert(Conversation {
                        conv_id: message.conv_id.clone(),
                        updated_at: now as i64,
                        title: None,
                        archived: false,
                        deleted: false,
                    });
                }
                self.add(
                    &message.conv_id,
                    Item::live("user", &message.message_id, &message.text, now as i64),
                );
            }
            Event::Tick => {
                if self.flight.as_ref().is_some_and(|f| now >= f.deadline) {
                    self.flight = None;
                }
                if let Some(o) = &mut self.open {
                    if o.typing_until.is_some_and(|t| now >= t) {
                        o.typing_until = None;
                    }
                }
            }
            Event::Live(event) => {
                match event {
                    Envelope::ConvList(ConvList {
                        conversations: Some(rows),
                    }) if matches!(
                        self.flight.as_ref().map(|f| &f.request),
                        Some(Request::List)
                    ) =>
                    {
                        let capped = rows.len() >= 2000;
                        self.list.retain(|c| {
                            !rows.iter().any(|r| r.conv_id == c.conv_id)
                                && (capped
                                    || self.open.as_ref().is_some_and(|o| o.conv_id == c.conv_id)
                                    || outbox.pending(&c.conv_id, None))
                        });
                        for c in rows {
                            self.upsert(c);
                        }
                        self.flight = None;
                        effects.push(Effect::Listed);
                    }
                    Envelope::History(History {
                        conv_id,
                        items: Some(items),
                        more,
                        ..
                    }) => {
                        if let Some(flight) = self.flight.as_ref().filter(|f| {
                            matches!(&f.request, Request::History {conv_id:id,..} if *id==conv_id)
                        }) {
                            let newest = matches!(flight.request, Request::History {before:None,..});
                            if let Some(o) = self.open.as_mut().filter(|o|o.conv_id==conv_id) {
                                if newest {
                                    o.items.retain(|i| {
                                        (i.kind=="user" && outbox.pending(&conv_id,Some(&i.id)))
                                        || (i.seq.is_none() && i.arrival>flight.arrival && !items.iter().any(|p|p.same_key(i)))
                                    });
                                }
                                for item in &items {
                                    o.items.retain(|i|!i.same_key(item));
                                    o.items.push(item.clone());
                                }
                                o.older_more=more;
                                effects.push(Effect::Page {conv_id,items:items.len(),more,newest});
                            }
                            self.flight=None;
                        }
                    }
                    Envelope::Error(_) => self.flight = None,
                    Envelope::MessageError(e) if e.code == "run_failed" => {
                        if let Some(o) = self
                            .open
                            .as_mut()
                            .filter(|o| e.conv_id.as_ref().is_none_or(|c| *c == o.conv_id))
                        {
                            for item in &mut o.items {
                                if item.kind == "user" && e.message_id.as_ref() == Some(&item.id) {
                                    item.run_failed = true;
                                }
                            }
                        }
                    }
                    Envelope::ConvUpdate(mut c) => {
                        if c.archived || c.deleted {
                            self.list.retain(|old| old.conv_id != c.conv_id);
                            if self.open.as_ref().is_some_and(|o| o.conv_id == c.conv_id) {
                                self.open = None;
                                effects.push(Effect::Notice(REMOVED));
                            }
                        } else {
                            c.updated_at = self
                                .list
                                .iter()
                                .find(|old| old.conv_id == c.conv_id)
                                .map_or(now as i64, |old| old.updated_at);
                            self.upsert(c);
                        }
                        effects.push(Effect::Listed);
                    }
                    Envelope::Reply(r) => {
                        if let Some(c) = self.list.iter_mut().find(|c| c.conv_id == r.conv_id) {
                            c.updated_at = c.updated_at.max(r.ts);
                        } else {
                            self.upsert(Conversation {
                                conv_id: r.conv_id.clone(),
                                updated_at: r.ts,
                                title: None,
                                archived: false,
                                deleted: false,
                            });
                        }
                        if let Some(o) = self.open.as_mut().filter(|o| o.conv_id == r.conv_id) {
                            o.typing_until = None;
                        }
                        self.add(
                            &r.conv_id,
                            Item::live("agent", &r.message_id, &r.text, r.ts),
                        );
                    }
                    Envelope::RunStarted(r) => {
                        if self.open.as_ref().is_some_and(|o| {
                            o.conv_id == r.conv_id
                                && !o
                                    .items
                                    .iter()
                                    .any(|i| i.kind == "user" && i.id == r.message_id)
                        }) {
                            // A page already in flight may predate this run.
                            let request = Request::History {
                                conv_id: r.conv_id,
                                before: None,
                            };
                            if self.online && !self.queue.contains(&request) {
                                self.queue.push_back(request);
                            }
                        }
                    }
                    Envelope::Typing(t) => {
                        if let Some(o) = self.open.as_mut().filter(|o| o.conv_id == t.conv_id) {
                            o.typing_until = t.active.then_some(now + 30_000);
                        }
                    }
                    Envelope::Tool(t) if t.call.known() => {
                        if let Some(o) = self.open.as_mut().filter(|o| o.conv_id == t.conv_id) {
                            if let Some(i) = o
                                .items
                                .iter_mut()
                                .find(|i| i.kind == "tools" && i.id == t.message_id)
                            {
                                i.tools.retain(|c| c.call_id != t.call.call_id);
                                i.tools.push(t.call);
                            } else {
                                let mut item = Item::live("tools", &t.message_id, "", now as i64);
                                item.tools.push(t.call);
                                self.add(&t.conv_id, item);
                            }
                        }
                    }
                    _ => {}
                }
            }
        }
        if let Some(o) = &mut self.open {
            o.items
                .sort_by_key(|i| (i.seq.is_none(), i.seq.unwrap_or(0), i.arrival));
        }
        self.list.sort_by_key(|c| std::cmp::Reverse(c.updated_at));
        if self.online && self.flight.is_none() {
            if let Some(request) = self.queue.pop_front() {
                let envelope = match &request {
                    Request::List => Envelope::ConvList(ConvList {
                        conversations: None,
                    }),
                    Request::History { conv_id, before } => Envelope::History(History {
                        conv_id: conv_id.clone(),
                        before: *before,
                        items: None,
                        more: false,
                    }),
                };
                self.flight = Some(Flight {
                    request,
                    arrival: self.arrival,
                    deadline: now + 30_000,
                });
                effects.push(Effect::Send(envelope));
            }
        }
        effects
    }
    fn enqueue(&mut self, request: Request) {
        if self.online
            && !self.queue.contains(&request)
            && !self.flight.as_ref().is_some_and(|f| f.request == request)
        {
            self.queue.push_back(request);
        }
    }
    fn upsert(&mut self, conv: Conversation) {
        self.list.retain(|c| c.conv_id != conv.conv_id);
        if !conv.archived && !conv.deleted {
            self.list.push(conv);
        }
    }
    fn add(&mut self, conv_id: &str, mut item: Item) {
        if let Some(o) = self.open.as_mut().filter(|o| o.conv_id == conv_id) {
            self.arrival += 1;
            item.arrival = self.arrival;
            o.items.retain(|i| !i.same_key(&item));
            o.items.push(item);
        }
    }
}
