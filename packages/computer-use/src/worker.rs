//! Private bounded context for one ordinary model's computer-use worker.
//! A host scheduler owns durability and routes recursive delegation by TaskIds.
use crate::contract::*;
use std::collections::VecDeque;

pub struct WorkerContext {
    goal: WorkerGoal,
    history: VecDeque<BatchResult>,
}
impl WorkerContext {
    pub fn new(goal: WorkerGoal) -> Result<Self, String> {
        crate::executor::validate_ids(&goal.ids)?;
        if goal.goal.is_empty()
            || goal.goal.len() > 4096
            || goal.context.len() > 16384
            || goal.authorization.is_empty()
            || goal.authorization.len() > 4096
        {
            return Err("worker goal/context/authorization exceeds bounds".into());
        }
        Ok(Self {
            goal,
            history: VecDeque::new(),
        })
    }
    pub fn goal(&self) -> &WorkerGoal {
        &self.goal
    }
    /// Only the worker's provider adapter receives this history. Main receives outcome().
    pub fn history(&self) -> &VecDeque<BatchResult> {
        &self.history
    }
    pub fn steer(&mut self, ids: &TaskIds, context: String) -> Result<(), String> {
        if *ids != self.goal.ids || context.len() > 16384 {
            return Err("invalid worker steering".into());
        }
        self.goal.context = context;
        Ok(())
    }
    pub fn record(&mut self, result: BatchResult) -> Result<(), String> {
        if result.ids != self.goal.ids || result.results.len() > 32 {
            return Err("result outside worker context".into());
        }
        if result.results.iter().any(|r| {
            r.detail.len() > 2048
                || r.observation
                    .as_ref()
                    .is_some_and(|o| o.image.len() > 12 * 1024 * 1024)
        }) {
            return Err("worker result exceeds bounds".into());
        }
        // Keep at most two image payloads, but preserve their observation IDs in
        // metadata for older steps. The executor alone decides whether IDs are fresh.
        self.history.push_back(result);
        let mut images = 0;
        for batch in self.history.iter_mut().rev() {
            for step in batch.results.iter_mut().rev() {
                if let Some(o) = &mut step.observation {
                    images += 1;
                    if images > 2 {
                        o.image = Vec::new();
                    }
                }
            }
        }
        while self.history.len() > 16 {
            self.history.pop_front();
        }
        Ok(())
    }
    /// Summary is the worker model's claim; the secretary must review evidence.
    pub fn outcome(&self, status: WorkerStatus, summary: String) -> Result<WorkerOutcome, String> {
        if summary.len() > 2048 {
            return Err("worker summary exceeds bounds".into());
        }
        let evidence_ids = self
            .history
            .iter()
            .flat_map(|b| &b.results)
            .filter_map(|r| r.observation.as_ref().map(|o| o.observation_id.clone()))
            .rev()
            .take(16)
            .collect();
        Ok(WorkerOutcome {
            ids: self.goal.ids.clone(),
            status,
            summary,
            evidence_ids,
            last_batch: self.history.back().map(|batch| BatchSummary {
                batch_id: batch.batch_id.clone(),
                statuses: batch.results.iter().map(|r| r.status).collect(),
                input_halted: batch.input_halted,
                rejection: batch.rejection.clone(),
            }),
        })
    }
}
