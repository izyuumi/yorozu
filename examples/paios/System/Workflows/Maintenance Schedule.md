# Maintenance Schedule

PAIOS defines jobs but does not install host schedules by itself. Configure your agent runtime or the host scheduler to invoke them.

Recommended schedule in the owner's local time zone (set `PAIOS_TZ`):

| Cycle | Suggested time | Workflow | Skip behavior |
|---|---|---|---|
| Daily | 02:00 each day | `Daily Maintenance.md` | Catch up next run using last successful cursor |
| Weekly | 03:00 Monday | `Weekly Maintenance.md` | Run after pending daily consolidation |
| Monthly | 04:00 first day | `Monthly Maintenance.md` | Never overlap an active migration |

## Scheduler requirements

- run only one maintenance cycle or migration at a time;
- record start, covered-through cursor, success, warnings, and report path;
- use explicit time zone and handle daylight-saving changes if the user moves;
- catch up idempotently after downtime rather than replaying completed windows;
- surface repeated failures in the execution queue;
- do not perform external side-effect actions merely because maintenance discovered them;
- allow the user to change the schedule without editing constitutional principles.

