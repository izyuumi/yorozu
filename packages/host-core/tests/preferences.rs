//! Synthetic admission/storage contracts. The module is intentionally not wired into the host.
#[path = "../src/preferences.rs"]
mod preferences;

use preferences::*;
use std::{
    fs,
    path::PathBuf,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
};

static ID: AtomicU64 = AtomicU64::new(0);
struct Temp(PathBuf);
impl Temp {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "yorozu-preferences-{}-{}-{}",
            std::process::id(),
            yorozu_host_core::now_ms(),
            ID.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        Self(root)
    }
    fn store(&self) -> PathBuf {
        self.0.join("preferences-v1")
    }
    fn open(&self) -> Preferences {
        Preferences::open(&self.store(), &owner()).unwrap()
    }
}
impl Drop for Temp {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}
fn owner() -> Owner {
    Owner {
        user_id: "synthetic-user".into(),
        host_id: "synthetic-host".into(),
    }
}
fn budget() -> Budget {
    Budget {
        max_records: 32,
        max_bytes: 32_768,
    }
}
fn change(id: &str, scope: Scope, revision: u64, accepted: u64, action: Action) -> Change {
    Change {
        event_id: id.into(),
        scope,
        key: Key::ReplyBulletCount,
        expected_revision: revision,
        source: Source {
            message_id: format!("message-{id}"),
            task_id: Some("synthetic-origin-task".into()),
            accepted_sequence: accepted,
            observed_at_ms: 1000,
        },
        action,
    }
}
fn set(id: &str, scope: Scope, count: u8, accepted: u64) -> Change {
    change(
        id,
        scope,
        0,
        accepted,
        Action::Set(Value::ReplyBulletCount(count)),
    )
}
fn count(store: &Preferences, context: &Context) -> Option<Value> {
    store
        .retrieve(context, budget())
        .unwrap()
        .records
        .into_iter()
        .find(|record| record.key == Key::ReplyBulletCount)
        .and_then(|record| record.value)
}

#[test]
fn explicit_en_ja_correction_survives_other_topics_and_a_fresh_process() {
    if let Ok(root) = std::env::var("YOROZU_SYNTHETIC_PREFERENCE_RESTART") {
        let root = PathBuf::from(root);
        assert!(
            root.parent()
                .unwrap()
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("yorozu-preferences-")
        );
        let store = Preferences::open(&root, &owner()).unwrap();
        assert_eq!(
            count(
                &store,
                &Context {
                    task_id: Some("new-worker".into()),
                    project_id: None
                }
            ),
            Some(Value::ReplyBulletCount(2))
        );
        let latest = store
            .latest(&Scope::Global, Key::ReplyBulletCount)
            .unwrap()
            .unwrap();
        assert_eq!(
            (
                latest.revision,
                latest.supersedes,
                latest.source.message_id.as_str()
            ),
            (2, Some(1), "message-correction")
        );
        let expected = if std::env::var("YOROZU_SYNTHETIC_LANGUAGE").unwrap() == "ja" {
            Language::Japanese
        } else {
            Language::English
        };
        assert_eq!(
            store
                .latest(&Scope::Global, Key::ReplyLanguage)
                .unwrap()
                .unwrap()
                .value,
            Some(Value::ReplyLanguage(expected))
        );
        let retrieved = store
            .retrieve(
                &Context {
                    task_id: Some("new-worker".into()),
                    project_id: None,
                },
                budget(),
            )
            .unwrap();
        assert_eq!(retrieved.records.len(), 2);
        assert!(
            retrieved
                .records
                .iter()
                .all(|record| record.scope == Scope::Global)
        );
        assert!(!retrieved.markdown().contains("message-unrelated"));
        assert!(
            store
                .retrieve(&Context::default(), budget())
                .unwrap()
                .markdown()
                .contains("message-correction")
        );
        return;
    }
    // Explicit synthetic utterances: "Use 3 bullets" -> "Actually, use 2";
    // 「箇条書きは3つにして」->「訂正、2つにして」. Admission/extraction is separate.
    for (label, language) in [("en", Language::English), ("ja", Language::Japanese)] {
        let temp = Temp::new();
        let mut store = temp.open();
        store.apply(&set("initial", Scope::Global, 3, 1)).unwrap();
        let mut correction = change(
            "correction",
            Scope::Global,
            1,
            2,
            Action::Correct(Value::ReplyBulletCount(2)),
        );
        correction.source.observed_at_ms = 1; // Clock drift cannot undo admission precedence.
        store.apply(&correction).unwrap();
        let mut lang = change(
            "language",
            Scope::Global,
            0,
            3,
            Action::Set(Value::ReplyLanguage(language)),
        );
        lang.key = Key::ReplyLanguage;
        store.apply(&lang).unwrap();
        store
            .apply(&set(
                "unrelated",
                Scope::Project("other-topic".into()),
                7,
                4,
            ))
            .unwrap();
        drop(store); // No provider history, summary, or in-memory projection reaches the child.
        let output = Command::new(std::env::current_exe().unwrap())
            .args([
                "--exact",
                "explicit_en_ja_correction_survives_other_topics_and_a_fresh_process",
                "--nocapture",
            ])
            .env("YOROZU_SYNTHETIC_PREFERENCE_RESTART", temp.store())
            .env("YOROZU_SYNTHETIC_LANGUAGE", label)
            .output()
            .unwrap();
        assert!(
            output.status.success(),
            "{label}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        assert!(
            String::from_utf8_lossy(&output.stdout).contains("1 passed; 0 failed"),
            "restart subprocess must execute its assertion-bearing test"
        );
    }
}

#[test]
fn revisions_admission_order_and_idempotency_reject_stale_or_conflicting_writes() {
    let temp = Temp::new();
    let mut store = temp.open();
    let initial = set("initial", Scope::Global, 3, 20);
    assert!(!store.apply(&initial).unwrap().replayed);
    let correction = change(
        "newer",
        Scope::Global,
        1,
        30,
        Action::Correct(Value::ReplyBulletCount(2)),
    );
    let receipt = store.apply(&correction).unwrap();
    assert_eq!(
        (
            receipt.record.sequence,
            receipt.record.revision,
            receipt.record.supersedes
        ),
        (2, 2, Some(1))
    );
    let stale_revision = change(
        "stale-revision",
        Scope::Global,
        1,
        40,
        Action::Correct(Value::ReplyBulletCount(6)),
    );
    assert!(matches!(
        store.apply(&stale_revision),
        Err(Error::RevisionConflict {
            current_revision: 2
        })
    ));
    let stale_source = change(
        "stale-source",
        Scope::Global,
        2,
        25,
        Action::Correct(Value::ReplyBulletCount(6)),
    );
    assert!(matches!(
        store.apply(&stale_source),
        Err(Error::StaleSource)
    ));
    assert!(store.apply(&initial).unwrap().replayed); // Replaying old admission cannot reactivate it.
    assert_eq!(
        store.apply(&correction).unwrap(),
        Receipt {
            record: receipt.record,
            replayed: true
        }
    );
    let mut conflict = correction.clone();
    conflict.action = Action::Correct(Value::ReplyBulletCount(5));
    assert!(matches!(store.apply(&conflict), Err(Error::EventConflict)));
    assert_eq!(
        count(&store, &Context::default()),
        Some(Value::ReplyBulletCount(2))
    );
    assert_eq!(
        store
            .retrieve(&Context::default(), budget())
            .unwrap()
            .journal_sequence,
        2
    );
}

#[test]
fn scoped_overrides_and_deletions_never_leak_other_tasks_or_fall_back_to_stale_values() {
    let temp = Temp::new();
    let mut store = temp.open();
    let project = Scope::Project("project-a".into());
    let task = Scope::Task("task-a".into());
    store.apply(&set("global", Scope::Global, 3, 1)).unwrap();
    store.apply(&set("project", project.clone(), 4, 2)).unwrap();
    store.apply(&set("task", task.clone(), 2, 3)).unwrap();
    store
        .apply(&set("other", Scope::Task("task-b".into()), 9, 4))
        .unwrap();
    let context = Context {
        project_id: Some("project-a".into()),
        task_id: Some("task-a".into()),
    };
    assert_eq!(count(&store, &context), Some(Value::ReplyBulletCount(2)));
    assert_eq!(
        count(
            &store,
            &Context {
                project_id: context.project_id.clone(),
                task_id: None
            }
        ),
        Some(Value::ReplyBulletCount(4))
    );
    assert_eq!(
        count(&store, &Context::default()),
        Some(Value::ReplyBulletCount(3))
    );
    store
        .apply(&change("delete-task", task.clone(), 1, 5, Action::Delete))
        .unwrap();
    assert_eq!(count(&store, &context), None); // Tombstone masks both project/global defaults.
    let invalid_restore = change(
        "implicit-restore",
        task.clone(),
        2,
        6,
        Action::Correct(Value::ReplyBulletCount(6)),
    );
    assert!(matches!(
        store.apply(&invalid_restore),
        Err(Error::StateConflict)
    ));
    let restore = change(
        "explicit-restore",
        task.clone(),
        2,
        6,
        Action::Set(Value::ReplyBulletCount(5)),
    );
    store.apply(&restore).unwrap();
    assert_eq!(count(&store, &context), Some(Value::ReplyBulletCount(5)));
    // A fresh task may explicitly decline an inherited global value without storing an override first.
    store
        .apply(&change(
            "mask-inheritance",
            Scope::Task("new-task".into()),
            0,
            7,
            Action::Delete,
        ))
        .unwrap();
    assert_eq!(
        count(
            &store,
            &Context {
                task_id: Some("new-task".into()),
                project_id: None
            }
        ),
        None
    );
}

#[test]
fn deletion_redacts_only_its_scoped_history_and_stays_deleted_after_restart() {
    let temp = Temp::new();
    let mut store = temp.open();
    let original = set("initial", Scope::Global, 3, 1);
    store.apply(&original).unwrap();
    store
        .apply(&change(
            "correct",
            Scope::Global,
            1,
            2,
            Action::Correct(Value::ReplyBulletCount(2)),
        ))
        .unwrap();
    store
        .apply(&set("task", Scope::Task("kept-task".into()), 7, 3))
        .unwrap();
    let deleted = store
        .apply(&change("delete", Scope::Global, 2, 4, Action::Delete))
        .unwrap();
    assert_eq!(
        (deleted.record.revision, deleted.record.supersedes),
        (3, Some(2))
    );
    let redacted = store.apply(&original).unwrap();
    assert!(redacted.record.redacted);
    // Every valid guess must return the same redacted receipt: no deleted-value oracle.
    for guess in 1..=12 {
        let guessed = set("initial", Scope::Global, guess, 1);
        assert_eq!(store.apply(&guessed).unwrap(), redacted);
    }
    let mut mismatched_provenance = original.clone();
    mismatched_provenance.source.message_id = "different-message".into();
    assert!(matches!(
        store.apply(&mismatched_provenance),
        Err(Error::EventConflict)
    ));
    let db = rusqlite::Connection::open(temp.store().join("preferences.sqlite")).unwrap();
    let fingerprint: String = db
        .query_row(
            "SELECT request_hash FROM events WHERE event_id='initial'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert!(
        fingerprint.is_empty(),
        "redaction must remove value-dependent persisted fingerprints"
    );
    drop(db);
    drop(store);
    let store = temp.open();
    let history = store
        .history(&Scope::Global, Key::ReplyBulletCount, 100)
        .unwrap();
    assert_eq!(history.len(), 3);
    assert_eq!(history[0].operation, Operation::Delete);
    assert!(history.iter().all(|record| record.value.is_none()));
    assert!(history[1..].iter().all(|record| record.redacted));
    assert_eq!(history[2].source.message_id, "message-initial");
    assert_eq!(count(&store, &Context::default()), None);
    assert_eq!(
        count(
            &store,
            &Context {
                task_id: Some("kept-task".into()),
                project_id: None
            }
        ),
        Some(Value::ReplyBulletCount(7))
    );
    assert_eq!(
        store
            .history(&Scope::Global, Key::ReplyBulletCount, 1)
            .unwrap()
            .len(),
        1
    );
}

#[test]
fn bounded_retrieval_omits_whole_latest_records_and_reports_an_invalidation_token() {
    let temp = Temp::new();
    let mut store = temp.open();
    store.apply(&set("global", Scope::Global, 3, 1)).unwrap();
    for (id, key, value) in [
        (
            "language",
            Key::ReplyLanguage,
            Value::ReplyLanguage(Language::Japanese),
        ),
        (
            "questions",
            Key::ClarificationStyle,
            Value::ClarificationStyle(ClarificationStyle::NecessaryOnly),
        ),
    ] {
        let mut update = change(id, Scope::Global, 0, 2, Action::Set(value));
        update.key = key;
        store.apply(&update).unwrap();
    }
    let full = store.retrieve(&Context::default(), budget()).unwrap();
    assert_eq!((full.records.len(), full.omitted), (3, 0));
    assert_eq!(
        full.payload_bytes,
        serde_json::to_vec(&full.records).unwrap().len()
    );
    let short = store
        .retrieve(
            &Context::default(),
            Budget {
                max_records: 1,
                max_bytes: 32_768,
            },
        )
        .unwrap();
    assert_eq!((short.records.len(), short.omitted), (1, 2));
    let exactly_one = short.payload_bytes;
    let exact = store
        .retrieve(
            &Context::default(),
            Budget {
                max_records: 32,
                max_bytes: exactly_one,
            },
        )
        .unwrap();
    assert_eq!(exact.records.len(), 1);
    let tiny = store
        .retrieve(
            &Context::default(),
            Budget {
                max_records: 32,
                max_bytes: 2,
            },
        )
        .unwrap();
    assert_eq!(
        (tiny.records.len(), tiny.omitted, tiny.payload_bytes),
        (0, 3, 2)
    );
    store
        .apply(&set("task", Scope::Task("task".into()), 2, 3))
        .unwrap();
    let omitted_override = store
        .retrieve(
            &Context {
                task_id: Some("task".into()),
                project_id: None,
            },
            Budget {
                max_records: 0,
                max_bytes: 2,
            },
        )
        .unwrap();
    assert!(omitted_override.records.is_empty());
    assert_eq!(omitted_override.omitted, 3);
    assert!(omitted_override.journal_sequence > full.journal_sequence);
}

#[test]
fn trust_boundary_rejects_free_form_authority_invalid_data_and_foreign_store_owners() {
    let temp = Temp::new();
    let mut store = temp.open();
    assert!(matches!(
        Preferences::open(std::path::Path::new("synthetic-relative-root"), &owner()),
        Err(Error::InvalidInput)
    ));
    let valid = set("valid", Scope::Global, 2, 1);
    let mut cases = Vec::new();
    let mut invalid = valid.clone();
    invalid.action = Action::Set(Value::ReplyBulletCount(0));
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.action = Action::Set(Value::ReplyBulletCount(13));
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.action = Action::Set(Value::ReplyLanguage(Language::English));
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.event_id = "execute arbitrary shell".into();
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.scope = Scope::Project("../vault".into());
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.source.accepted_sequence = 0;
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.source.observed_at_ms = u64::MAX;
    cases.push(invalid);
    let mut invalid = valid.clone();
    invalid.source.task_id = Some("".into());
    cases.push(invalid);
    for invalid in cases {
        assert!(matches!(store.apply(&invalid), Err(Error::InvalidInput)));
    }
    assert!(serde_json::from_str::<Value>(r#"{"kind":"grantPermissions","value":"all"}"#).is_err());
    assert!(
        serde_json::from_str::<Value>(r#"{"kind":"replyLanguage","value":"run a command"}"#)
            .is_err()
    );
    assert!(matches!(
        store.retrieve(
            &Context::default(),
            Budget {
                max_records: 33,
                max_bytes: 1000
            }
        ),
        Err(Error::InvalidInput)
    ));
    assert!(matches!(
        store.retrieve(
            &Context::default(),
            Budget {
                max_records: 1,
                max_bytes: 1
            }
        ),
        Err(Error::InvalidInput)
    ));
    assert!(matches!(
        store.history(&Scope::Global, Key::ReplyBulletCount, 101),
        Err(Error::InvalidInput)
    ));
    store.apply(&valid).unwrap();
    drop(store);
    for wrong in [
        Owner {
            user_id: "other-user".into(),
            ..owner()
        },
        Owner {
            host_id: "other-host".into(),
            ..owner()
        },
    ] {
        assert!(matches!(
            Preferences::open(&temp.store(), &wrong),
            Err(Error::InvalidInput)
        ));
    }
    assert_eq!(
        count(&temp.open(), &Context::default()),
        Some(Value::ReplyBulletCount(2))
    );
    let foreign = Temp::new();
    {
        let store = foreign.open();
        drop(store);
    }
    let db = rusqlite::Connection::open(foreign.store().join("preferences.sqlite")).unwrap();
    db.pragma_update(None, "application_id", 0).unwrap();
    drop(db);
    let before = fs::read(foreign.store().join("preferences.sqlite")).unwrap();
    assert!(matches!(
        Preferences::open(&foreign.store(), &owner()),
        Err(Error::InvalidInput)
    ));
    assert_eq!(
        fs::read(foreign.store().join("preferences.sqlite")).unwrap(),
        before
    );
}

#[test]
fn one_writer_and_transaction_rollback_preserve_acknowledged_values() {
    let temp = Temp::new();
    let mut store = temp.open();
    assert!(Preferences::open(&temp.store(), &owner()).is_err());
    store.apply(&set("initial", Scope::Global, 3, 1)).unwrap();
    let db = rusqlite::Connection::open(temp.store().join("preferences.sqlite")).unwrap();
    // SQLite itself fails the insert AFTER the deletion's redaction, exercising rollback.
    db.execute_batch("CREATE TRIGGER fail_insert BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'synthetic storage failure'); END;").unwrap();
    assert!(matches!(
        store.apply(&change("delete", Scope::Global, 1, 2, Action::Delete)),
        Err(Error::Storage(_))
    ));
    assert_eq!(
        count(&store, &Context::default()),
        Some(Value::ReplyBulletCount(3))
    );
    assert!(
        !store
            .history(&Scope::Global, Key::ReplyBulletCount, 1)
            .unwrap()[0]
            .redacted
    );
    db.execute_batch("DROP TRIGGER fail_insert;").unwrap();
    drop(db);
    drop(store);
    let mut store = temp.open();
    store
        .apply(&change("delete", Scope::Global, 1, 2, Action::Delete))
        .unwrap();
    assert_eq!(count(&store, &Context::default()), None);
}

#[test]
fn a_full_journal_reserves_room_to_delete_acknowledged_preferences() {
    let temp = Temp::new();
    let mut store = temp.open();
    store.apply(&set("initial", Scope::Global, 3, 1)).unwrap();
    let mut revision = 1;
    loop {
        assert!(
            revision < 5000,
            "the declared journal ceiling must be enforced"
        );
        let next = change(
            &format!("capacity-{revision}"),
            Scope::Global,
            revision,
            revision + 1,
            Action::Correct(Value::ReplyBulletCount(2 + (revision % 2) as u8)),
        );
        match store.apply(&next) {
            Ok(_) => revision += 1,
            Err(Error::Capacity) => break,
            Err(error) => panic!("unexpected storage error: {error}"),
        }
    }
    assert_eq!(revision, 4096); // Independently documented storage ceiling.
    store
        .apply(&change(
            "full-delete",
            Scope::Global,
            revision,
            revision + 1,
            Action::Delete,
        ))
        .unwrap();
    assert_eq!(count(&store, &Context::default()), None);
    assert!(
        store
            .history(&Scope::Global, Key::ReplyBulletCount, 100)
            .unwrap()
            .iter()
            .all(|record| record.value.is_none())
    );
    // The reserve cannot be consumed by new keys, redundant tombstones, or restorations.
    assert!(matches!(
        store.apply(&set(
            "new-key",
            Scope::Task("new-key".into()),
            2,
            revision + 2
        )),
        Err(Error::Capacity)
    ));
    assert!(matches!(
        store.apply(&change(
            "absent-mask",
            Scope::Task("absent-key".into()),
            0,
            revision + 2,
            Action::Delete
        )),
        Err(Error::Capacity)
    ));
    assert!(matches!(
        store.apply(&change(
            "redundant",
            Scope::Global,
            revision + 1,
            revision + 2,
            Action::Delete
        )),
        Err(Error::Capacity)
    ));
    assert!(matches!(
        store.apply(&change(
            "restore",
            Scope::Global,
            revision + 1,
            revision + 2,
            Action::Set(Value::ReplyBulletCount(2))
        )),
        Err(Error::Capacity)
    ));
    drop(store);
    assert_eq!(count(&temp.open(), &Context::default()), None);
}
