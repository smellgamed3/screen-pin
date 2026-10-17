use super::*;
use std::cell::Cell;

fn config() -> Config {
    Config {
        displays: vec![DisplayRecord {
            id: "left".into(),
            name: "工作屏".into(),
            fingerprints: vec!["serial:a".into()],
        }],
        profiles: vec![Profile {
            id: "desk".into(),
            name: "桌面".into(),
            display_ids: vec!["left".into()],
            applications: vec![],
        }],
        ..Config::default()
    }
}

fn window() -> WindowSnapshot {
    WindowSnapshot {
        handle: 123,
        pid: 42,
        token: 1,
        process_started: 987,
        app_id: "c:\\editor\\code.exe".into(),
        app_name: "Code".into(),
        title: "screen-pin — Visual Studio Code".into(),
        display_key: "monitor-a".into(),
        normal_rect: Rect {
            left: 100,
            top: 100,
            right: 900,
            bottom: 700,
        },
        maximized: false,
    }
}

fn placement(x: f64) -> Placement {
    Placement {
        display_id: "left".into(),
        rect: RelativeRect {
            x,
            y: 0.1,
            width: 0.5,
            height: 0.7,
        },
        maximized: false,
    }
}

fn saved(_: &Config) -> Result<(), String> {
    Ok(())
}
fn failed(_: &Config) -> Result<(), String> {
    Err("disk full".into())
}

#[test]
fn first_case_insensitive_title_rule_wins_and_falls_back_to_default() {
    let mut engine = Engine::new(config()).unwrap();
    let window = window();
    engine
        .remember("desk", &window, placement(0.0), saved)
        .unwrap();
    engine
        .create_rule("desk", &window, "SCREEN", placement(0.1), saved)
        .unwrap();
    engine
        .create_rule("desk", &window, "screen-pin", placement(0.2), saved)
        .unwrap();
    let matched = engine.match_window("desk", &window).unwrap().unwrap();
    assert_eq!(matched.preset.placement, placement(0.1));
    assert!(matches!(
        matched.kind,
        MatchKind::Rule {
            index: 0,
            keyword: "SCREEN"
        }
    ));
    engine
        .remember("desk", &window, placement(0.3), saved)
        .unwrap();
    assert_eq!(
        engine
            .match_window("desk", &window)
            .unwrap()
            .unwrap()
            .preset
            .placement,
        placement(0.3)
    );
    let mut renamed = window;
    renamed.title = "unrelated document".into();
    let matched = engine.match_window("desk", &renamed).unwrap().unwrap();
    assert_eq!(matched.kind, MatchKind::Default);
    assert_eq!(matched.preset.placement, placement(0.0));
}

#[test]
fn same_filename_different_application_path_never_shares_preset() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    let mut other = window();
    other.app_id = "d:\\editor\\code.exe".into();
    assert!(engine.match_window("desk", &other).unwrap().is_none());
}

#[test]
fn explicit_default_can_be_created_after_matching_rule_and_undone_without_removing_rule() {
    let mut engine = Engine::new(config()).unwrap();
    let window = window();
    engine
        .create_rule("desk", &window, "screen", placement(0.0), saved)
        .unwrap();
    let original_rule = engine.config().profiles[0].applications[0].rules[0].clone();

    engine
        .create_default("desk", &window, placement(0.2), saved)
        .unwrap();
    let app = &engine.config().profiles[0].applications[0];
    assert_eq!(app.default.as_ref().unwrap().placement, placement(0.2));
    assert_eq!(app.rules[0], original_rule);
    assert_eq!(
        engine
            .match_window("desk", &window)
            .unwrap()
            .unwrap()
            .preset
            .id,
        original_rule.preset.id
    );
    engine.undo(saved).unwrap();
    let app = &engine.config().profiles[0].applications[0];
    assert!(app.default.is_none());
    assert_eq!(app.rules, vec![original_rule.clone()]);

    engine
        .create_default("desk", &window, placement(0.2), saved)
        .unwrap();
    engine
        .remember("desk", &window, placement(0.4), saved)
        .unwrap();
    let app = &engine.config().profiles[0].applications[0];
    assert_eq!(app.default.as_ref().unwrap().placement, placement(0.2));
    assert_eq!(app.rules[0].preset.placement, placement(0.4));
}

#[test]
fn explicit_default_rejects_existing_default_without_saving_or_replacing_undo() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .create_default("desk", &window(), placement(0.0), saved)
        .unwrap();
    let before = engine.config().clone();
    let undo = engine.undo_label().map(str::to_owned);
    assert!(
        engine
            .create_default("desk", &window(), placement(0.3), |_| panic!(
                "duplicate default reached storage"
            ))
            .is_err()
    );
    assert_eq!(engine.config(), &before);
    assert_eq!(engine.undo_label(), undo.as_deref());
    engine.undo(saved).unwrap();
    assert!(engine.config().profiles[0].applications.is_empty());
}

#[test]
fn explicit_default_failed_save_preserves_rule_and_previous_undo() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .create_rule("desk", &window(), "screen", placement(0.0), saved)
        .unwrap();
    let before = engine.config().clone();
    let undo = engine.undo_label().map(str::to_owned);
    assert!(
        engine
            .create_default("desk", &window(), placement(0.2), failed)
            .is_err()
    );
    assert_eq!(engine.config(), &before);
    assert_eq!(engine.undo_label(), undo.as_deref());
    engine.undo(saved).unwrap();
    assert!(engine.config().profiles[0].applications.is_empty());
}

#[test]
fn failed_save_preserves_config_and_previous_undo() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    let previous = engine.config().clone();
    let undo_label = engine.undo_label().unwrap().to_owned();
    assert_eq!(
        engine.remember("desk", &window(), placement(0.2), failed),
        Err("disk full".into())
    );
    assert_eq!(engine.config(), &previous);
    assert_eq!(engine.undo_label(), Some(undo_label.as_str()));
    assert!(engine.undo(failed).is_err());
    assert_eq!(engine.config(), &previous);
    assert_eq!(engine.undo_label(), Some(undo_label.as_str()));
    engine.undo(saved).unwrap();
    assert!(engine.config().profiles[0].applications.is_empty());
}

#[test]
fn unchanged_remember_does_not_save_or_replace_useful_undo() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    engine
        .remember("desk", &window(), placement(0.25), saved)
        .unwrap();
    let previous = engine.config().clone();
    let calls = Cell::new(0);
    let outcome = engine
        .remember("desk", &window(), placement(0.25), |_| {
            calls.set(calls.get() + 1);
            Ok(())
        })
        .unwrap();
    assert_eq!(outcome, ChangeOutcome::Unchanged);
    assert_eq!(calls.get(), 0);
    assert_eq!(engine.config(), &previous);
    engine.undo(saved).unwrap();
    assert_eq!(
        engine
            .match_window("desk", &window())
            .unwrap()
            .unwrap()
            .preset
            .placement,
        placement(0.0)
    );
}

#[test]
fn consecutive_edits_undo_only_last_edit_and_use_monotonic_versions() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    engine
        .remember("desk", &window(), placement(0.1), saved)
        .unwrap();
    engine
        .remember("desk", &window(), placement(0.2), saved)
        .unwrap();
    let revision = engine.config().revision;
    engine.undo(saved).unwrap();
    let matched = engine.match_window("desk", &window()).unwrap().unwrap();
    assert_eq!(matched.preset.placement, placement(0.1));
    assert_eq!(matched.preset.revision, revision + 1);
    assert_eq!(engine.config().revision, revision + 1);
    assert!(engine.undo_label().is_none());
}

#[test]
fn rule_order_and_settings_preserve_undo_while_target_deletion_invalidates_it() {
    let mut engine = Engine::new(config()).unwrap();
    let window = window();
    engine
        .create_rule("desk", &window, "screen", placement(0.0), saved)
        .unwrap();
    engine
        .create_rule("desk", &window, "Code", placement(0.2), saved)
        .unwrap();
    let rule_id = engine.config().profiles[0].applications[0].rules[1]
        .preset
        .id
        .clone();
    engine
        .move_rule("desk", &window.app_id, &rule_id, -1, saved)
        .unwrap();
    assert!(engine.undo_label().is_some());
    let mut candidate = engine.config().clone();
    candidate.settings.autostart = true;
    engine.commit_config(candidate, saved).unwrap();
    assert!(engine.undo_label().is_some());
    engine.undo(saved).unwrap();
    let app = &engine.config().profiles[0].applications[0];
    assert_eq!(app.rules.len(), 1);
    assert_eq!(app.rules[0].keyword, "screen");
    assert!(engine.config().settings.autostart);
    engine
        .remember("desk", &window, placement(0.4), saved)
        .unwrap();
    let rule_id = engine.config().profiles[0].applications[0].rules[0]
        .preset
        .id
        .clone();
    engine
        .delete("desk", &window.app_id, &rule_id, saved)
        .unwrap();
    assert!(engine.undo_label().is_none());
}

#[test]
fn keyword_edit_can_be_undone_without_reverting_later_sorting() {
    let mut engine = Engine::new(config()).unwrap();
    let window = window();
    engine
        .create_rule("desk", &window, "screen", placement(0.0), saved)
        .unwrap();
    engine
        .create_rule("desk", &window, "Code", placement(0.2), saved)
        .unwrap();
    let id = engine.config().profiles[0].applications[0].rules[1]
        .preset
        .id
        .clone();
    engine
        .edit(
            "desk",
            &window.app_id,
            &id,
            placement(0.3),
            Some("editor"),
            saved,
        )
        .unwrap();
    engine
        .move_rule("desk", &window.app_id, &id, -1, saved)
        .unwrap();
    engine.undo(saved).unwrap();
    let first = &engine.config().profiles[0].applications[0].rules[0];
    assert_eq!(first.keyword, "Code");
    assert_eq!(first.preset.placement, placement(0.2));
}

#[test]
fn structural_reassociation_and_direct_conflicting_change_invalidate_undo() {
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    let mut candidate = engine.config().clone();
    candidate.displays[0].fingerprints = vec!["serial:b".into()];
    engine.commit_config(candidate, saved).unwrap();
    assert!(engine.undo_label().is_none());
    engine
        .remember("desk", &window(), placement(0.1), saved)
        .unwrap();
    let mut candidate = engine.config().clone();
    candidate.profiles[0].applications[0]
        .default
        .as_mut()
        .unwrap()
        .placement = placement(0.3);
    engine.commit_config(candidate, saved).unwrap();
    assert!(engine.undo_label().is_none());
}

#[test]
fn stale_candidate_is_rejected_without_persistence() {
    let mut engine = Engine::new(config()).unwrap();
    let candidate = engine.config().clone();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    assert!(
        engine
            .commit_config(candidate, |_| panic!("stale write reached storage"))
            .is_err()
    );
    assert!(engine.require_revision(0).is_err());
}

#[test]
fn invalid_rules_and_cross_profile_display_are_rejected_without_mutation() {
    let mut engine = Engine::new(config()).unwrap();
    let before = engine.config().clone();
    assert!(
        engine
            .create_rule("desk", &window(), "  ", placement(0.0), saved)
            .is_err()
    );
    let mut wrong_display = placement(0.0);
    wrong_display.display_id = "unconnected".into();
    assert!(
        engine
            .remember("desk", &window(), wrong_display, saved)
            .is_err()
    );
    assert_eq!(engine.config(), &before);
    engine
        .create_rule("desk", &window(), "Screen", placement(0.0), saved)
        .unwrap();
    let before = engine.config().clone();
    assert!(
        engine
            .create_rule("desk", &window(), "SCREEN", placement(0.1), saved)
            .is_err()
    );
    assert_eq!(engine.config(), &before);
}

#[test]
fn negative_coordinates_and_reserved_taskbar_work_area_roundtrip_without_drift() {
    let work = Rect {
        left: -1920,
        top: 48,
        right: 0,
        bottom: 1080,
    };
    let mut rect = Rect {
        left: -1837,
        top: 111,
        right: -671,
        bottom: 991,
    };
    let original = rect;
    for _ in 0..100 {
        let relative = RelativeRect::from_rect(rect, work).unwrap();
        rect = relative.to_rect(work).unwrap();
        assert_eq!(rect, original);
    }
    let spanning = Rect {
        left: -2020,
        top: 10,
        right: 300,
        bottom: 1200,
    };
    let relative = RelativeRect::from_rect(spanning, work).unwrap();
    assert!(relative.x < 0.0 && relative.width > 1.0);
    assert_eq!(relative.to_rect(work).unwrap(), spanning);
}

#[test]
fn resolution_change_preserves_relative_position_and_checks_overflow() {
    let relative = RelativeRect {
        x: 0.0,
        y: 0.0,
        width: 0.5,
        height: 1.0,
    };
    assert_eq!(
        relative
            .to_rect(Rect {
                left: 100,
                top: -1440,
                right: 2660,
                bottom: 0
            })
            .unwrap(),
        Rect {
            left: 100,
            top: -1440,
            right: 1380,
            bottom: 0
        }
    );
    let invalid = RelativeRect {
        x: f64::INFINITY,
        ..relative
    };
    assert!(invalid.validate().is_err());
    let overflow = RelativeRect {
        x: 1e20,
        ..relative
    };
    assert!(
        overflow
            .to_rect(Rect {
                left: 0,
                top: 0,
                right: 1920,
                bottom: 1080
            })
            .is_err()
    );
    assert!(
        RelativeRect {
            width: 0.0,
            ..relative
        }
        .validate()
        .is_err()
    );
    assert!(
        Rect {
            left: i32::MIN,
            right: i32::MAX,
            top: 0,
            bottom: 1
        }
        .validate()
        .is_err()
    );
}

#[test]
fn config_rejects_future_schema_duplicate_combinations_and_unknown_fields() {
    let mut invalid = config();
    invalid.schema_version += 1;
    assert!(invalid.validate().is_err());
    let mut invalid = config();
    let mut second = invalid.profiles[0].clone();
    second.id = "duplicate-combination".into();
    invalid.profiles.push(second);
    assert!(invalid.validate().is_err());
    let mut value = serde_json::to_value(config()).unwrap();
    value
        .as_object_mut()
        .unwrap()
        .insert("unrecognized".into(), true.into());
    assert!(serde_json::from_value::<Config>(value).is_err());
}

#[test]
fn config_catches_invalid_hotkeys_and_dangling_preset_references() {
    let mut invalid = config();
    invalid.settings.remember = invalid.settings.restore;
    assert!(invalid.validate().is_err());
    assert!(
        Hotkey {
            modifiers: 0,
            key: 0x78
        }
        .validate()
        .is_err()
    );
    assert!(
        Hotkey {
            modifiers: 3,
            key: 0x10
        }
        .validate()
        .is_err()
    );
    assert_eq!(Settings::default().restore.label(), "Ctrl+Alt+F9");
    let mut engine = Engine::new(config()).unwrap();
    engine
        .remember("desk", &window(), placement(0.0), saved)
        .unwrap();
    let mut invalid = engine.config().clone();
    invalid.profiles[0].applications[0]
        .default
        .as_mut()
        .unwrap()
        .placement
        .display_id = "missing".into();
    assert!(invalid.validate().is_err());
}
