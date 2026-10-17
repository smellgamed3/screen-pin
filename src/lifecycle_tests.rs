use super::*;

fn args() -> Vec<String> {
    [
        "screen-pin",
        "--config-dir",
        r"C:\Users\测试 User\AppData\Local\ScreenPin",
        "--handoff-parent-pid",
        "123456789",
        "--handoff-parent-started",
        "987654321",
        "--handoff-nonce",
        "0123456789abcdef-0123456789abcdef",
        "--handoff-reservation-handle",
        "1234",
    ]
    .iter()
    .map(|s| (*s).into())
    .collect()
}

fn parent() -> Identity {
    Identity {
        sid: "S-1-5-21-1000".into(),
        session: 1,
        started: 987654321,
        executable: r"C:\Screen Pin\screen-pin.exe".into(),
        elevated: false,
    }
}

#[test]
fn ordinary_startup_has_no_handoff_and_complete_arguments_are_parsed() {
    assert!(!is_preparing_child());
    assert_eq!(
        HandoffArgs::parse(&["screen-pin".into(), "--startup".into()]).unwrap(),
        None
    );
    let parsed = HandoffArgs::parse(&args()).unwrap().unwrap();
    assert_eq!(parsed.parent_pid, 123456789);
    assert_eq!(parsed.parent_started, 987654321);
    assert_eq!(parsed.reservation_handle, 1234);
}

#[test]
fn incomplete_duplicate_unknown_and_injected_event_names_are_rejected() {
    let mut missing = args();
    missing.pop();
    assert!(HandoffArgs::parse(&missing).is_err());
    let mut duplicate = args();
    duplicate.extend(["--handoff-parent-pid".into(), "42".into()]);
    assert!(HandoffArgs::parse(&duplicate).is_err());
    let mut unknown = args();
    unknown.extend(["--handoff-unknown".into(), "yes".into()]);
    assert!(HandoffArgs::parse(&unknown).is_err());
    for invalid in [
        r"Global\any-event",
        "short",
        "0123456789abcdef/parent",
        "0123456789abcdef --flag",
    ] {
        let mut invalid_args = args();
        let position = invalid_args
            .iter()
            .position(|arg| arg == "--handoff-nonce")
            .unwrap();
        invalid_args[position + 1] = invalid.into();
        assert!(HandoffArgs::parse(&invalid_args).is_err());
    }
    for invalid in ["0", "-1", "not-a-handle"] {
        let mut invalid_args = args();
        *invalid_args.last_mut().unwrap() = invalid.into();
        assert!(HandoffArgs::parse(&invalid_args).is_err());
    }
}

#[test]
fn cross_account_cross_session_pid_reuse_different_binary_and_non_elevated_are_refused() {
    let parent = parent();
    let mut valid = parent.clone();
    valid.elevated = true;
    valid.started += 1;
    assert!(validate_identity(&parent, &valid, parent.started).is_ok());
    assert!(validate_identity(&parent, &valid, parent.started + 1).is_err());
    let mut other_user = valid.clone();
    other_user.sid = "S-1-5-21-2000".into();
    assert!(validate_identity(&parent, &other_user, parent.started).is_err());
    let mut other_session = valid.clone();
    other_session.session = 2;
    assert!(validate_identity(&parent, &other_session, parent.started).is_err());
    let mut other_binary = valid.clone();
    other_binary.executable = r"C:\Other\screen-pin.exe".into();
    assert!(validate_identity(&parent, &other_binary, parent.started).is_err());
    valid.elevated = false;
    assert!(validate_identity(&parent, &valid, parent.started).is_err());
}

#[test]
fn windows_parameter_quoting_preserves_spaces_quotes_and_trailing_backslashes() {
    assert_eq!(quote_argument(""), "\"\"");
    assert_eq!(
        quote_argument(r"C:\Program Files\测试\"),
        "\"C:\\Program Files\\测试\\\\\""
    );
    assert_eq!(quote_argument("a\"b"), "\"a\\\"b\"");
}

#[test]
fn handoff_cannot_release_writer_before_preparation_or_commit_before_readiness() {
    let mut state = Transfer::new();
    assert!(state.advance(Phase::Released).is_err());
    state.advance(Phase::Prepared).unwrap();
    state.advance(Phase::Released).unwrap();
    assert!(state.advance(Phase::Committed).is_err());
    state.advance(Phase::Ready).unwrap();
    state.advance(Phase::Committed).unwrap();
    assert!(state.advance(Phase::Aborting).is_err());
}

#[test]
fn rollback_cannot_resume_writer_without_confirming_child_exit() {
    for phase in [
        Phase::ParentOwns,
        Phase::Prepared,
        Phase::Released,
        Phase::Ready,
    ] {
        let mut state = Transfer { phase };
        state.advance(Phase::Aborting).unwrap();
        assert!(state.advance(Phase::Recovered).is_err());
        state.advance(Phase::ChildExited).unwrap();
        state.advance(Phase::Recovered).unwrap();
    }
}
