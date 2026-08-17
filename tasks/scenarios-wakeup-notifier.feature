# Scenarios: Vast.ai wakeup notifier and training runner

# Probes for `prd-wakeup-notifier.md`. Observable behavior only.
# Not an implementation spec.

Feature: Host start, training run, lifecycle notices, and instance stop

  After install, a Vast.ai host start fetches one public training repo,
  runs train.sh, sends one message per lifecycle event, and stops the
  instance unless a keep flag is present.

  # --- Happy path ---

  @SC-01 @G-02 @FR-31 @FR-07 @FR-29 @FR-33 @FR-35 @AC-16 @AC-17 @BR-11
  Scenario: Successful unattended start trains and stops the instance
    Given this project is installed at /workspace/vastai
    And the orchestrator env file has one configured channel and a Vast.ai API key
    And the training-repo env file names a public git URL
    And the training repo has a runnable train.sh at its root
    And neither KEEP_ALIVE nor KEEP_ALIVE_PERMANENT exists
    When the host starts
    Then exactly one host-up notice is sent
    And the training repo is cloned or updated under /workspace using the default branch
    And exactly one repo-update notice is sent
    And train.sh is started at the training-repo root with no extra arguments
    And exactly one training-started notice is sent
    And when train.sh exits successfully exactly one training-stopped notice is sent
    And exactly one host-is-shutting-down notice is sent
    And the Vast.ai instance is stopped via the API
    And the instance is not destroyed
    And none of those lifecycle notices is repeated as a nag loop

  @SC-02 @FR-26 @FR-36 @G-05 @AC-14 @BR-12
  Scenario: install.sh does not clone or train
    Given this project has been cloned to /workspace/vastai
    And env files are configured
    When the operator runs install.sh
    Then the training repository is not cloned or updated
    And train.sh is not started
    And the Vast.ai instance is not stopped by install.sh
    And a later host start will run the separate start script without running install.sh again

  # --- Config and channels ---

  @SC-03 @FR-02 @E-01 @AC-06 @BR-03
  Scenario: Missing channel configuration fails before host-up
    Given the orchestrator env file has a Vast.ai API key
    And the training-repo env file has a public git URL
    And no Telegram, SMTP, or SMS channel is fully configured
    When the host starts
    Then startup fails with an actionable message
    And no host-up notice is sent
    And train.sh is not started
    And the instance is not stopped by this product

  @SC-04 @FR-02 @E-01 @AC-06
  Scenario: Missing training git URL fails before host-up
    Given at least one channel is fully configured
    And the orchestrator env file has a Vast.ai API key
    And the training-repo env file has no public git URL
    When the host starts
    Then startup fails with an actionable message
    And train.sh is not started
    And the instance is not stopped by this product

  @SC-05 @FR-02 @E-01 @AC-06
  Scenario: Missing Vast.ai API key fails before host-up
    Given at least one channel is fully configured
    And the training-repo env file has a public git URL
    And the orchestrator env file has no Vast.ai API key
    When the host starts
    Then startup fails with an actionable message
    And train.sh is not started
    And no instance stop is attempted

  @SC-06 @FR-02 @NFR-07 @AC-06 @OQ-02
  Scenario: Loose env file permissions warn and continue
    Given startup would otherwise succeed
    And an env file is readable more broadly than owner-only 0600
    When the host starts
    Then an actionable warning is issued
    And the start-script sequence still proceeds

  @SC-07 @FR-09 @BR-03 @BR-04 @E-02 @NFR-03
  Scenario: One channel failing does not skip training or stop
    Given Telegram and SMTP are both configured
    And Telegram delivery fails
    And SMTP delivery succeeds
    And train.sh will exit successfully
    And no keep flag is present
    When the host starts
    Then SMTP still receives the lifecycle notices
    And train.sh still runs
    And the instance is still stopped

  @SC-08 @FR-21 @AC-07
  Scenario: Channel test does not train or stop
    Given env files are configured
    When the operator runs channel test mode
    Then configured channels are probed
    And the training repo is not cloned or updated
    And train.sh is not started
    And the instance is not stopped

  @SC-09 @FR-25 @NFR-20 @AC-12 @G-10
  Scenario: Public-IP lookup stays off by default
    Given public-IP lookup is not enabled
    When a host-up notice is sent
    Then no IP-lookup site is contacted

  @SC-10 @AC-09 @NFR-07
  Scenario: Secrets never appear in notices or logs
    Given the orchestrator env file contains a Vast.ai API key and channel credentials
    When the start script runs
    Then notices, logs, command arguments, and start-hook text do not contain those secrets

  # --- Git clone and update ---

  @SC-11 @FR-28 @AC-15 @G-08
  Scenario: Missing checkout is cloned under /workspace
    Given the training-repo URL ends with a repo named train-job
    And /workspace/train-job does not exist
    When the start script runs
    Then the public default branch is cloned to /workspace/train-job

  @SC-12 @FR-28 @AC-15 @AC-24
  Scenario: Update discards tracked edits and keeps new files
    Given /workspace/train-job already exists from a previous start
    And a tracked file in that checkout has local edits
    And an untracked new file exists in that checkout
    When the start script updates the training repo
    Then tracked files match the remote default branch
    And the untracked new file is still present

  # --- Training failures ---

  @SC-13 @FR-37 @FR-32 @E-10 @AC-19
  Scenario: Missing train.sh skips start and still stops
    Given clone or update of the training repo succeeds
    And train.sh is missing at the training-repo root
    And no keep flag is present
    When the start script runs
    Then a host-up notice is sent
    And a repo-update notice is sent
    And no training-started notice is sent
    And a training-stopped notice indicates training did not run
    And a host-is-shutting-down notice is sent
    And the instance is stopped

  @SC-14 @FR-32 @E-11 @AC-21
  Scenario: Failed train.sh is reported then the instance is stopped
    Given train.sh starts and later exits non-zero
    And no keep flag is present
    When the start script runs
    Then a training-started notice is sent
    And a training-stopped notice is sent and marked as failed
    And a host-is-shutting-down notice is sent
    And the instance is stopped

  @SC-15 @FR-38 @FR-32 @E-09 @AC-20
  Scenario: Clone failure skips training and stops
    Given the public training repo cannot be cloned or updated
    And no keep flag is present
    When the start script runs
    Then a host-up notice is sent
    And a notice indicates repo update failed
    And no training-started notice is sent
    And a training-stopped notice indicates training did not run
    And a host-is-shutting-down notice is sent
    And the instance is stopped

  # --- Keep flags and SSH ---

  @SC-16 @FR-34 @E-12 @AC-18 @BR-09
  Scenario: KEEP_ALIVE created during this start prevents stop
    Given train.sh will exit successfully
    And KEEP_ALIVE_PERMANENT does not exist
    When the operator creates empty /workspace/KEEP_ALIVE after this start has begun and before stop is decided
    Then no host-is-shutting-down notice is sent
    And the instance is not stopped

  @SC-17 @FR-34 @FR-39 @E-13 @AC-22 @BR-14
  Scenario: SSH login creates KEEP_ALIVE and prevents stop
    Given the SSH keep hook is enabled
    And train.sh is still running
    When the operator opens an SSH session with SSH_CONNECTION
    Then empty /workspace/KEEP_ALIVE is created
    And /workspace/KEEP_ALIVE_PERMANENT is not created
    And when training later ends the instance is not stopped
    And no host-is-shutting-down notice is sent

  @SC-18 @FR-34 @AC-23 @E-04
  Scenario: Leftover KEEP_ALIVE does not keep the next unattended start
    Given a previous start left /workspace/KEEP_ALIVE on disk
    And KEEP_ALIVE_PERMANENT does not exist
    And the operator does not SSH during the new start
    And train.sh will exit successfully
    When the host starts unattended
    Then leftover KEEP_ALIVE is not honored
    And a host-is-shutting-down notice is sent
    And the instance is stopped

  @SC-19 @FR-34 @AC-23 @AC-18
  Scenario: KEEP_ALIVE_PERMANENT prevents stop across restarts
    Given /workspace/KEEP_ALIVE_PERMANENT exists
    And train.sh will exit successfully
    When the host starts
    Then the instance is not stopped
    And no host-is-shutting-down notice is sent
    When the host later starts again with that file still present
    Then the instance is not stopped

  @SC-20 @FR-34 @AC-18
  Scenario: Failed training still stays up when a keep flag is present
    Given train.sh will exit non-zero
    And the operator creates KEEP_ALIVE before the stop decision
    When the start script runs
    Then a training-stopped notice is sent and marked as failed
    And no host-is-shutting-down notice is sent
    And the instance is not stopped

  @SC-21 @FR-39
  Scenario: SSH keep hook can be disabled
    Given the SSH keep hook has been disabled
    When the operator opens an SSH session with SSH_CONNECTION
    Then /workspace/KEEP_ALIVE is not created by that hook

  # --- Concurrency and session ---

  @SC-22 @FR-01 @NFR-04 @FR-03 @E-06
  Scenario: Concurrent host start does not overlap training runs
    Given a start-script session is already running train.sh
    When host start is invoked again
    Then a second overlapping training run is not started
    And an unrelated process is not stopped because of a stale process id

  @SC-23 @G-02 @BR-11 @E-04
  Scenario: A later start sends the lifecycle sequence again
    Given a previous start already sent host-up and later stopped the instance
    And no keep flags remain that would skip stop
    When the host starts again
    Then a new host-up notice is sent
    And the training repo is updated or cloned again
    And train.sh runs again

  # --- Local / off-host ---

  @SC-24 @NG-03 @E-07
  Scenario: No boot or network promises no notices
    Given the instance never becomes usable
    Then no lifecycle notices are required
    And no training run is required
    And no instance stop is required
