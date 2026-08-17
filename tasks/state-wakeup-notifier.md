# Workflow State: Vast.ai wakeup notifier

- **Current phase:** task_planning
- **Product Gate:** approved
- **Technical Design Gate:** approved
- **Task Plan Gate:** pending
- **System Acceptance:** pending
- **Traceability Audit:** pending

## Artifacts
- Task Description: `td-wakeup-notifier.md`
- PRD: `prd-wakeup-notifier.md`
- Scenarios: `scenarios-wakeup-notifier.feature`
- Repository Analysis: `repo-analysis-wakeup-notifier.md`
- Architecture: `architecture-wakeup-notifier.md`
- Tasks: _not created_
- Acceptance: _not created_
- Traceability: _not created_

## Approval / Change History
- 2026-08-16 Feature workflow initialized. Draft PRD created from `README.md` and `old-PRD.md`. Product Gate not approved.
- 2026-08-16 User decisions: (1) any one of Telegram / SMTP / SMS; (2) `wakeup.env` mode >0600 warns and continues; (3) PRD is completed v1; (7) default install path `/workspace/vastai`. OQ-04, OQ-05, OQ-06 unanswered. Product Gate still pending.
- 2026-08-16 User decisions: (4) keep empty ACK for local testing, not on Vast.ai host; (5) keep optional public-IP lookup; (6) no Jupyter use, `ack.sh` is enough. Open questions cleared. Product Gate still pending explicit approval.
- 2026-08-16 User changed product intent: deploy via clone + `install.sh`; env file names training repo; on deploy/restart clone-or-update that repo and run `train.sh`; keep wakeup nags; also notify repo update / train start / train finish; shutdown after training unless a keep flag exists. Product Gate not approved. OQ-08–OQ-18 open.
- 2026-08-16 Training-amendment answers: one-shot messages (host up / repo update / training started / stopped / shutting down); public git URL only in a separate env file; checkout under `/workspace`; `train.sh` at root, missing → stop unless keep flag; clone failure → notify, skip train, stop unless keep flag; empty `KEEP_ALIVE` and `KEEP_ALIVE_PERMANENT`; stop not destroy, API key in orchestrator env; `install.sh` first-time only, separate script does clone/train. User asked to clarify former Q2 (ACK vs shutdown) and Q7 (`train.sh` non-zero). Product Gate still pending.
- 2026-08-16 Confirmations: SSH login creates `KEEP_ALIVE`; `train.sh` non-zero → training stopped (failed) then stop unless keep flag; `KEEP_ALIVE` this start only, `KEEP_ALIVE_PERMANENT` until deleted; git update discards tracked edits, keeps new/untracked files. Open questions cleared. Product Gate still pending explicit approval.
- 2026-08-16 User accepted the PRD as the v1 contract. Scenarios written in `scenarios-wakeup-notifier.feature`. Product Gate not marked approved until PRD+scenarios are explicitly approved together. No architecture.
- 2026-08-16 Product Gate approved for `prd-wakeup-notifier.md` and `scenarios-wakeup-notifier.feature`. Phase set to repository_analysis. Technical Design Gate still pending.
- 2026-08-16 Repository analysis written to `repo-analysis-wakeup-notifier.md`. Phase set to architecture. Technical Design Gate still pending. No architecture plan yet.
- 2026-08-17 Architecture decisions: (1) require `VAST_INSTANCE_ID` in orchestrator env; (2) new `bin/start.sh` orchestrator; (3) onstart `nohup`s `start.sh`. Plan written to `architecture-wakeup-notifier.md`. Technical Design Gate pending explicit approval.
- 2026-08-17 Technical Design Gate approved for `architecture-wakeup-notifier.md`. Phase set to task_planning. Task Plan Gate still pending.
