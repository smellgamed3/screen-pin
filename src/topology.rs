use crate::model::{Config, DisplayRecord, MonitorSnapshot, Profile, next_id};
use crate::protocol::DisplayBinding;
use std::collections::HashSet;

fn serials(fingerprints: &[String]) -> Vec<&String> {
    fingerprints
        .iter()
        .filter(|f| f.starts_with("serial:") && f.len() > "serial:".len())
        .collect()
}

// An EDID can supply both a binary serial and an ASCII serial descriptor. An
// equal binary value cannot overrule a conflicting ASCII value (or vice versa).
// Legacy/simple serial strings belong to one common category.
fn serial_kind(value: &str) -> &str {
    value
        .rfind(":number:")
        .map(|p| &value[..p + ":number".len()])
        .or_else(|| value.rfind(":text:").map(|p| &value[..p + ":text".len()]))
        .unwrap_or("serial")
}

fn evidence_conflicts(left: &[String], right: &[String]) -> bool {
    let left_serials = serials(left);
    let right_serials = serials(right);
    let serial_conflict = left_serials.iter().any(|a| {
        right_serials
            .iter()
            .any(|b| serial_kind(a) == serial_kind(b) && a != b)
    });
    let left_models: Vec<_> = left.iter().filter(|f| f.starts_with("model:")).collect();
    let right_models: Vec<_> = right.iter().filter(|f| f.starts_with("model:")).collect();
    let model_conflict = !left_models.is_empty()
        && !right_models.is_empty()
        && !left_models.iter().any(|f| right_models.contains(f));
    serial_conflict || model_conflict
}

fn shared_kind(left: &[String], right: &[String], prefix: &str) -> bool {
    left.iter()
        .any(|f| f.starts_with(prefix) && right.contains(f))
}

fn merged_evidence(old: &[String], new: &[String]) -> Vec<String> {
    let mut merged = new.to_vec();
    // Losing EDID access is not evidence that a previously established serial
    // ceased to exist. Keep it; connector paths describe the current attachment.
    for fingerprint in old.iter().filter(|f| f.starts_with("serial:")) {
        if !merged.contains(fingerprint) {
            merged.push(fingerprint.clone());
        }
    }
    merged.sort();
    merged.dedup();
    merged
}

pub struct Resolution {
    pub active_profile: Option<String>,
    pub bindings: Vec<DisplayBinding>,
    pub needs_association: bool,
    pub candidate: Option<Config>,
}

/// Match evidence, never screen position or enumeration order.
pub fn resolve(config: &Config, monitors: &[MonitorSnapshot]) -> Result<Resolution, String> {
    if monitors.is_empty() {
        return Err("未找到参与桌面的显示器".into());
    }
    let mut candidate = config.clone();
    let mut bindings = Vec::new();
    let mut used = HashSet::new();
    let mut ambiguous = false;
    for monitor in monitors {
        let monitor_serials = serials(&monitor.fingerprints);
        let serial_overlap_with_conflict = config.displays.iter().any(|display| {
            shared_kind(&display.fingerprints, &monitor.fingerprints, "serial:")
                && evidence_conflicts(&display.fingerprints, &monitor.fingerprints)
        });
        if serial_overlap_with_conflict {
            // Do not choose a second record or create a new environment while
            // available strong identity evidence contradicts itself.
            ambiguous = true;
            continue;
        }
        let matching: Vec<_> = config
            .displays
            .iter()
            .filter(|display| {
                if evidence_conflicts(&display.fingerprints, &monitor.fingerprints) {
                    return false;
                }
                if !monitor_serials.is_empty() {
                    return shared_kind(&display.fingerprints, &monitor.fingerprints, "serial:")
                        || (serials(&display.fingerprints).is_empty()
                            && shared_kind(&display.fingerprints, &monitor.fingerprints, "path:"));
                }
                shared_kind(&display.fingerprints, &monitor.fingerprints, "path:")
            })
            .collect();
        // Duplicate serials are not unique identities, even if paths happen to differ.
        if !config.displays.is_empty()
            && !monitor_serials.is_empty()
            && monitors
                .iter()
                .filter(|m| m.fingerprints.iter().any(|s| monitor_serials.contains(&s)))
                .count()
                > 1
        {
            ambiguous = true;
            continue;
        }
        if matching.len() == 1 {
            let id = &matching[0].id;
            if !used.insert(id.clone()) {
                ambiguous = true;
                continue;
            }
            bindings.push(DisplayBinding {
                display_id: id.clone(),
                monitor_key: monitor.key.clone(),
            });
            let record = candidate
                .displays
                .iter_mut()
                .find(|display| display.id == *id)
                .unwrap();
            let fingerprints = merged_evidence(&record.fingerprints, &monitor.fingerprints);
            // Avoid writes for mere evidence ordering differences.
            let mut previous = record.fingerprints.clone();
            previous.sort();
            previous.dedup();
            if previous != fingerprints {
                record.fingerprints = fingerprints;
            }
            record.name = monitor.name.clone();
        } else if matching.len() > 1 {
            ambiguous = true;
        } else {
            let could_be_old = config.displays.iter().any(|display| {
                // A serial newly becoming readable cannot identify a previous
                // serial-less screen on another connector using model alone.
                (monitor_serials.is_empty() || serials(&display.fingerprints).is_empty())
                    && (shared_kind(&display.fingerprints, &monitor.fingerprints, "model:")
                        || shared_kind(&display.fingerprints, &monitor.fingerprints, "path:"))
            });
            if could_be_old || monitor.fingerprints.iter().all(|f| f.starts_with("model:")) {
                ambiguous = true;
                continue;
            }
            let id = next_id();
            candidate.displays.push(DisplayRecord {
                id: id.clone(),
                name: monitor.name.clone(),
                fingerprints: monitor.fingerprints.clone(),
            });
            used.insert(id.clone());
            bindings.push(DisplayBinding {
                display_id: id,
                monitor_key: monitor.key.clone(),
            });
        }
    }
    if ambiguous || bindings.len() != monitors.len() {
        // A unique compatible combination may be known without identifying each
        // individual target. Keep only established bindings usable in that profile.
        let possible: Vec<_> = config
            .profiles
            .iter()
            .filter(|profile| compatible_profile(config, profile, monitors, &bindings))
            .collect();
        let active_profile = (possible.len() == 1).then(|| possible[0].id.clone());
        bindings.retain(|binding| config.displays.iter().any(|d| d.id == binding.display_id));
        return Ok(Resolution {
            active_profile,
            bindings,
            needs_association: true,
            candidate: None,
        });
    }
    let mut ids: Vec<_> = bindings.iter().map(|b| b.display_id.clone()).collect();
    ids.sort();
    let active_profile = match candidate.profiles.iter().find(|p| {
        let mut existing = p.display_ids.clone();
        existing.sort();
        existing == ids
    }) {
        Some(profile) => profile.id.clone(),
        None => {
            let id = next_id();
            candidate.profiles.push(Profile {
                id: id.clone(),
                name: format!("{} 屏方案", ids.len()),
                display_ids: ids,
                applications: Vec::new(),
            });
            id
        }
    };
    let changed = candidate != *config;
    Ok(Resolution {
        active_profile: Some(active_profile),
        bindings,
        needs_association: false,
        candidate: changed.then_some(candidate),
    })
}

fn compatible_profile(
    config: &Config,
    profile: &Profile,
    monitors: &[MonitorSnapshot],
    bindings: &[DisplayBinding],
) -> bool {
    if profile.display_ids.len() != monitors.len()
        || bindings
            .iter()
            .any(|b| !profile.display_ids.contains(&b.display_id))
    {
        return false;
    }
    let known: HashSet<_> = bindings.iter().map(|b| b.display_id.as_str()).collect();
    let choices: Vec<Vec<usize>> = monitors
        .iter()
        .map(|monitor| {
            if let Some(binding) = bindings.iter().find(|b| b.monitor_key == monitor.key) {
                return profile
                    .display_ids
                    .iter()
                    .position(|id| id == &binding.display_id)
                    .into_iter()
                    .collect();
            }
            profile
                .display_ids
                .iter()
                .enumerate()
                .filter_map(|(index, id)| {
                    if known.contains(id.as_str()) {
                        return None;
                    }
                    let display = config.displays.iter().find(|d| &d.id == id)?;
                    let plausible =
                        !evidence_conflicts(&display.fingerprints, &monitor.fingerprints)
                            && ["serial:", "path:"].iter().any(|prefix| {
                                shared_kind(&display.fingerprints, &monitor.fingerprints, prefix)
                            });
                    plausible.then_some(index)
                })
                .collect()
        })
        .collect();
    // Bipartite matching proves the combination can explain every current screen;
    // it deliberately does not publish the speculative per-screen assignment.
    fn assign(
        screen: usize,
        choices: &[Vec<usize>],
        owners: &mut [Option<usize>],
        visited: &mut [bool],
    ) -> bool {
        for &display in &choices[screen] {
            if visited[display] {
                continue;
            }
            visited[display] = true;
            if owners[display].is_none_or(|previous| assign(previous, choices, owners, visited)) {
                owners[display] = Some(screen);
                return true;
            }
        }
        false
    }
    let mut owners = vec![None; profile.display_ids.len()];
    (0..monitors.len()).all(|screen| {
        assign(
            screen,
            &choices,
            &mut owners,
            &mut vec![false; profile.display_ids.len()],
        )
    })
}

pub fn associate(
    config: &Config,
    profile_id: &str,
    bindings: &[DisplayBinding],
    monitors: &[MonitorSnapshot],
) -> Result<Config, String> {
    let profile = config.profile(profile_id).ok_or("方案不存在")?;
    if bindings.len() != profile.display_ids.len() || bindings.len() != monitors.len() {
        return Err("旧方案和当前显示器数量必须一致，请为每台屏幕建立关联".into());
    }
    let mut targets = HashSet::new();
    let mut sources = HashSet::new();
    for b in bindings {
        if !profile.display_ids.contains(&b.display_id)
            || !targets.insert(&b.display_id)
            || !sources.insert(&b.monitor_key)
            || !monitors.iter().any(|m| m.key == b.monitor_key)
        {
            return Err("显示器关联必须完整且一对一".into());
        }
    }
    let mut candidate = config.clone();
    for b in bindings {
        let monitor = monitors.iter().find(|m| m.key == b.monitor_key).unwrap();
        let display = candidate
            .displays
            .iter_mut()
            .find(|d| d.id == b.display_id)
            .ok_or("旧显示器不存在")?;
        // An explicit association replaces stale paths while retaining the user's logical ID.
        display.fingerprints = monitor.fingerprints.clone();
        display.name = monitor.name.clone();
    }
    candidate.validate()?;
    Ok(candidate)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Rect;
    fn monitor(key: &str, serial: &str, left: i32) -> MonitorSnapshot {
        let rect = Rect {
            left,
            top: 0,
            right: left + 1920,
            bottom: 1080,
        };
        MonitorSnapshot {
            key: key.into(),
            name: "Screen".into(),
            rect,
            work: rect,
            fingerprints: vec![
                format!("path:{key}"),
                format!("serial:{serial}"),
                "model:same-model".into(),
            ],
        }
    }
    #[test]
    fn layout_and_order_do_not_change_combination() {
        let monitors = vec![monitor("a", "111", 0), monitor("b", "222", 1920)];
        let first = resolve(&Config::default(), &monitors).unwrap();
        let config = first.candidate.unwrap();
        let swapped = vec![monitor("b", "222", 0), monitor("a", "111", -1920)];
        let second = resolve(&config, &swapped).unwrap();
        assert_eq!(first.active_profile, second.active_profile);
        assert!(second.candidate.is_none());
        assert!(!second.needs_association);
    }
    #[test]
    fn changed_connector_matches_unique_serial() {
        let first = resolve(&Config::default(), &[monitor("old-port", "111", 0)]).unwrap();
        let config = first.candidate.unwrap();
        let next = resolve(&config, &[monitor("new-port", "111", 0)]).unwrap();
        assert_eq!(first.active_profile, next.active_profile);
        assert!(!next.needs_association);
    }
    #[test]
    fn ambiguous_identity_never_creates_replacement_profile() {
        let first = resolve(&Config::default(), &[monitor("a", "111", 0)]).unwrap();
        let config = first.candidate.unwrap();
        let mut unknown = monitor("new-port", "unknown", 0);
        unknown.fingerprints.retain(|f| !f.starts_with("serial:"));
        let next = resolve(&config, &[unknown]).unwrap();
        assert!(next.needs_association);
        assert!(next.active_profile.is_none());
        assert!(next.candidate.is_none());
    }
    #[test]
    fn duplicate_serial_is_not_unique() {
        let monitors = [monitor("a", "same", 0), monitor("b", "same", 1920)];
        let first = resolve(&Config::default(), &monitors).unwrap();
        let result = resolve(&first.candidate.unwrap(), &monitors).unwrap();
        assert!(result.needs_association);
        assert!(result.candidate.is_none());
    }
    #[test]
    fn association_rejects_two_old_targets_to_same_screen() {
        let monitors = vec![monitor("a", "111", 0), monitor("b", "222", 1920)];
        let first = resolve(&Config::default(), &monitors).unwrap();
        let config = first.candidate.unwrap();
        let profile = &config.profiles[0];
        let bad: Vec<_> = profile
            .display_ids
            .iter()
            .map(|id| DisplayBinding {
                display_id: id.clone(),
                monitor_key: "a".into(),
            })
            .collect();
        assert!(associate(&config, &profile.id, &bad, &monitors).is_err());
    }

    #[test]
    fn unique_inventory_keeps_identified_screen_available_when_other_targets_are_ambiguous() {
        let monitors = [
            monitor("a", "unique", 0),
            monitor("b", "duplicate", 1920),
            monitor("c", "duplicate", 3840),
        ];
        let first = resolve(&Config::default(), &monitors).unwrap();
        let config = first.candidate.unwrap();
        let result = resolve(&config, &monitors).unwrap();
        assert_eq!(result.active_profile, first.active_profile);
        assert!(result.needs_association);
        assert!(result.candidate.is_none());
        assert_eq!(result.bindings.len(), 1);
        assert_eq!(result.bindings[0].monitor_key, "a");
    }

    #[test]
    fn model_and_screen_count_alone_cannot_select_an_old_profile() {
        let monitors = [monitor("a", "111", 0), monitor("b", "222", 1920)];
        let config = resolve(&Config::default(), &monitors)
            .unwrap()
            .candidate
            .unwrap();
        let mut unidentified = monitor("unknown-port", "not-readable", 1920);
        unidentified
            .fingerprints
            .retain(|f| !f.starts_with("serial:"));
        let result = resolve(&config, &[monitors[0].clone(), unidentified]).unwrap();
        assert!(result.active_profile.is_none());
        assert!(result.needs_association);
        assert!(result.candidate.is_none());
    }
    fn with_edid_serials(key: &str, number: &str, text: &str) -> MonitorSnapshot {
        let mut m = monitor(key, "unused", 0);
        m.fingerprints.retain(|f| !f.starts_with("serial:"));
        m.fingerprints
            .push(format!("serial:1234:5678:number:{number}"));
        m.fingerprints.push(format!("serial:1234:5678:text:{text}"));
        m
    }
    #[test]
    fn conflicting_ascii_serial_cannot_be_overruled_by_equal_binary_serial() {
        let old = with_edid_serials("port-a", "0000002a", "physical-a");
        let first = resolve(&Config::default(), &[old]).unwrap();
        let config = first.candidate.unwrap();
        let next = resolve(
            &config,
            &[with_edid_serials("port-b", "0000002a", "physical-b")],
        )
        .unwrap();
        assert!(next.needs_association);
        assert!(next.active_profile.is_none());
        assert!(next.bindings.is_empty());
        assert!(next.candidate.is_none());
    }
    #[test]
    fn conflicting_binary_serial_cannot_be_overruled_by_equal_ascii_serial() {
        let first = resolve(
            &Config::default(),
            &[with_edid_serials("port-a", "0000002a", "static")],
        )
        .unwrap();
        let config = first.candidate.unwrap();
        let next = resolve(
            &config,
            &[with_edid_serials("port-b", "0000002b", "static")],
        )
        .unwrap();
        assert!(next.needs_association);
        assert!(next.candidate.is_none());
    }
    #[test]
    fn newly_available_serial_enriches_unique_path_without_new_profile() {
        let mut old = monitor("same-port", "111", 0);
        old.fingerprints.retain(|f| !f.starts_with("serial:"));
        let first = resolve(&Config::default(), &[old]).unwrap();
        let config = first.candidate.unwrap();
        let original_display = config.displays[0].id.clone();
        let next = resolve(&config, &[monitor("same-port", "111", 0)]).unwrap();
        assert!(!next.needs_association);
        assert_eq!(next.active_profile, first.active_profile);
        assert_eq!(next.bindings[0].display_id, original_display);
        let updated = next.candidate.unwrap();
        assert_eq!(updated.profiles.len(), 1);
        assert!(
            updated.displays[0]
                .fingerprints
                .contains(&"serial:111".to_string())
        );
    }
    #[test]
    fn newly_available_serial_on_changed_port_cannot_guess_serial_less_old_screen() {
        let mut old = monitor("old-port", "111", 0);
        old.fingerprints.retain(|f| !f.starts_with("serial:"));
        let first = resolve(&Config::default(), &[old]).unwrap();
        let config = first.candidate.unwrap();
        let next = resolve(&config, &[monitor("new-port", "111", 0)]).unwrap();
        assert!(next.needs_association);
        assert!(next.candidate.is_none());
    }
    #[test]
    fn different_reliable_serial_is_a_new_screen_even_on_the_same_connector() {
        let first = resolve(&Config::default(), &[monitor("same-port", "111", 0)]).unwrap();
        let config = first.candidate.unwrap();
        let next = resolve(&config, &[monitor("same-port", "222", 0)]).unwrap();
        assert!(!next.needs_association);
        assert_ne!(next.active_profile, first.active_profile);
        let updated = next.candidate.unwrap();
        assert_eq!(updated.displays.len(), 2);
        assert_eq!(updated.profiles.len(), 2);
        assert_eq!(updated.displays[0], config.displays[0]);
    }
    #[test]
    fn temporarily_missing_serial_keeps_previous_identity_evidence() {
        let first = resolve(&Config::default(), &[monitor("same-port", "111", 0)]).unwrap();
        let config = first.candidate.unwrap();
        let mut without_serial = monitor("same-port", "111", 0);
        without_serial
            .fingerprints
            .retain(|f| !f.starts_with("serial:"));
        let next = resolve(&config, &[without_serial]).unwrap();
        assert_eq!(next.active_profile, first.active_profile);
        assert!(!next.needs_association);
        assert!(next.candidate.is_none());
    }
}
