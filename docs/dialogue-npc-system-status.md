# Dialogue & NPC System — Status Report

**Branch:** `cursor/godot-project-init-4804`  
**Pass:** **closed** (branching → debug tools + data-driven foundation)  
**Engine:** Godot 4.7  

This report classifies the **Dialogue & NPC System Pass**. It is the implemented foundation, not the full vision in [`docs/GAME_DESIGN.md`](GAME_DESIGN.md).  
Architecture: [`docs/architecture-status.md`](architecture-status.md) · Testing: [`docs/testing.md`](testing.md).

**Acceptance (scale):** New NPCs and dialogues are authored primarily as `.tres` Resources + catalog entries. Central scripts (`DialogueSystem`, `ConditionSystem`, `NpcStateSystem`, …) stay free of per-character name branches.

---

## Status legend

| Tag | Meaning |
|-----|---------|
| **READY** | Usable in the vertical slice; covered by smoke; data-driven |
| **PARTIAL** | Core works; missing content scale, polish, or design features |
| **NOT_IMPLEMENTED** | Explicitly out of this pass |

---

## Area status

| Area | Status | Notes |
|------|--------|-------|
| Dialogue resources (`DialogueDefinition` / `Choice` / `Action` / catalogs) | READY | Flat catalogs; link by id |
| Linear dialogue + advance / end | READY | `next_dialogue_id` |
| Branching choices (navigate / confirm) | READY | ↑↓ + continue |
| Hidden choices (`show_conditions`) | READY | e.g. Mira `terminal_repaired` |
| Disabled choices (`enable_conditions`) | READY | Visible `[indisponível]` |
| Line show + `fallback_dialogue_id` | READY | Loop-guarded |
| Contextual NPC resolve (`NpcDialogueRule` priority) | READY | Highest valid priority; fallback |
| ConditionSystem gates | READY | No quest/NPC ifs inside evaluator |
| Dialogue actions + once-guards | READY | Executor dispatch; enter/exit/choice once per conversation |
| Dialogue memory (seen / completed / choices) | READY | Save provider `dialogue_memory` |
| Interrupt / resume / cancel | READY | Session IDLE/ACTIVE/INTERRUPTED; resume keeps once-guards |
| NpcDefinition + NpcCharacter interact | READY | Resolve via DialogueSystem only |
| NpcStateSystem (mutable by `npc_id`) | READY | Save provider `npc_state`; no Node refs |
| Relationship / reputation | READY | Clamped −100..+100; conditions + actions |
| Narrative world time + availability windows | READY | Mira 08–18; conditions `NARRATIVE_*` |
| Overnight time range (e.g. 22–6) | READY | `NARRATIVE_TIME_RANGE` |
| NPC schedules (data-driven daily windows) | READY | Writes location/state; not physical path |
| Local NavigationAgent movement | READY | Markers under POI; snap on load |
| Dialogue pauses movement | READY | `NpcMovementController` pause reasons |
| Traveling NPCs (logical relocate) | READY | TRAVELING / AT_LOCATION; POI spawn gate |
| No traveler duplicate at old POI | READY | Smoke-checked |
| Contextual barks | READY | Label3D; cooldown / conditions; blocked by ACTIVE dialogue |
| Content validation (broken ids/links) | READY | `NpcDialogueContentValidator` + F10 panel |
| Dev debug panel (F10) | READY | Sandbox-only; isolated from ship gameplay |
| Quest hooks via dialogue actions | READY | START/COMPLETE via Executor; QuestSystem listens finished |
| Save/load of dialogue+NPC+relationship | READY | Mid-conversation session **not** persisted |
| Portraits / speaker art | NOT_IMPLEMENTED | Placeholder UI text only |
| Voice-over / lip sync | NOT_IMPLEMENTED | |
| Localization / string tables | NOT_IMPLEMENTED | Hardcoded PT/EN sample strings in `.tres` |
| Cinematic dialogue cameras | NOT_IMPLEMENTED | |
| Facial animation / emotes | NOT_IMPLEMENTED | |
| Romance / dating systems | NOT_IMPLEMENTED | Relationship is numeric only |
| Crowd / many simultaneous talkers | NOT_IMPLEMENTED | Two sample NPCs at Sunset Viewpoint |
| Multi-city physical traveler scenes | PARTIAL | Logical ids (e.g. `debug_waystation`); no second city scene |
| NPC animation set (walk/idle cycles) | PARTIAL | Moves via NavigationAgent; no final anim |
| Quest log UI | NOT_IMPLEMENTED | |
| Dialogue tree visual editor | NOT_IMPLEMENTED | F10 panel + validator only |
| Timed / QTÉ choices | NOT_IMPLEMENTED | |
| Audio bark / VO bark | NOT_IMPLEMENTED | Text Label3D only |
| Multi-language bark pools | NOT_IMPLEMENTED | |

---

## Full flow (1–16) — verified

Smoke covers the integrated path (dedicated slices + `dlg_npc_pass`):

1. Spawn by state / location / schedule  
2. Talk (interact → resolve)  
3. Contextual resolve (priority rules)  
4. Linear + branch  
5. Conditioned choices (hidden / disabled)  
6. Actions (+ once)  
7. Memory  
8. Relationship / reputation  
9. Narrative-time availability  
10. Schedule transition  
11. Local NavigationAgent move  
12. Dialogue pauses move  
13. Interrupt / resume (no dupe actions)  
14. Traveler relocate + no duplicate  
15. Bark (cooldown / condition)  
16. Save/load persistent dialogue+NPC+relationship state  

Invalid dialogue links: validator (catalog) + runtime safe end on missing `next_dialogue_id`.

---

## Architecture (coupling)

**Intent:** autoloads may *read* peers via `get_node_or_null`; no hard cycles at `_ready`; ConditionSystem is a pure query façade.

```
GameTimeSystem ──► NpcScheduleSystem ──► NpcStateSystem
                                      ▲
NpcTravelSystem ─────────────────────┘
     │
     └─► POI spawn gate (scene)

DialogueSystem ──► ConditionSystem ──► (flags/quest/inv/memory/npc/rel/time/travel…)
     │                ▲
     ├─► DialogueActionExecutor ──► flags/quest/inv/world/poi/npc/rel/travel
     └─► DialogueMemorySystem

BarkSystem ──► ConditionSystem; blocks when DialogueSystem ACTIVE
NpcMovementController ──► schedule signals + dialogue session signals; reads NpcState location
NpcCharacter (scene) ──► resolve/start dialogue; bark presenter; state sync
QuestSystem ── listens dialogue_finished; does not own dialogue text
RelationshipSystem ── written by Executor / read by ConditionSystem (no DialogueSystem import)
```

**Not owned by DialogueSystem:** pathfinding, POI placement, schedule authorship, action type dispatch, bark presentation, relationship math.

**Debug isolation:** `NpcDialogueDebugUI` / `NpcDialogueContentValidator` are sandbox/dev tools; gameplay autoloads do not reference them.

**Init note:** Schedule/Travel/Dialogue/Bark/Quest/Save bind peers in deferred `_initialize_dependencies` (READY state). Do not rely on `project.godot` order alone — see architecture-status §1.

---

## Smoke coverage map

| Scenario | Where |
|----------|--------|
| Branching | `_verify_dialogue_choices` + `dlg_npc_pass` |
| Hidden choice | `_verify_conditional_dialogue` + `dlg_npc_pass` |
| Disabled choice | `_verify_conditional_dialogue` + `dlg_npc_pass` |
| Dialogue fallback | `_verify_conditional_dialogue` |
| Action once | `_verify_dialogue_actions` + interrupt/resume pass |
| Memory save/load | `_verify_dialogue_memory` + `dlg_npc_pass` |
| NPC state save/load | `_verify_npc_state` + `dlg_npc_pass` |
| Relationship/reputation save/load | `_verify_relationship_system` + `dlg_npc_pass` |
| Narrative-time condition | `_verify_time_npc_availability` + `dlg_npc_pass` |
| Overnight range | `_verify_time_npc_availability` + `dlg_npc_pass` |
| Schedule transition | `_verify_npc_schedules` |
| Movement pause in dialogue | `_verify_npc_movement` |
| Traveler relocation / no dupe | `_verify_npc_travel` + `dlg_npc_pass` |
| Interrupt / resume no dupe | `_verify_dialogue_interrupt` + `dlg_npc_pass` |
| Bark cooldown / condition | `_verify_npc_barks` |
| Invalid link detection | validator + `dlg_npc_pass` runtime |
| Contextual priority | `_verify_npc_dialogue_rules` + `dlg_npc_pass` |
| Coupling audit | `dlg_npc_pass` |

Commands (see [`docs/testing.md`](testing.md)):

```bash
./run_tests.sh dialogue_smoke   # look for dialogue_smoke: OK
./run_tests.sh npc_smoke        # look for npc_smoke: OK
./run_tests.sh                  # full regression via drive_smoke
```

---

## Future needs (do not implement in this pass)

- Portraits, VO, localization tables  
- Cinematic talk cameras, facial / emote layers  
- Romance / deep social sim  
- Crowds, multi-speaker scenes, second physical city for travelers  
- Final NPC animation set, avoidance  
- Quest log UI, dialogue tree editor  
- Gas/service stops and broader world content ([`GAME_DESIGN.md`](GAME_DESIGN.md) roadmap)

---

## Related docs

| Doc | Role |
|-----|------|
| [`README.md`](../README.md) | How to run + capability summary |
| [`docs/GAME_DESIGN.md`](GAME_DESIGN.md) | Product vision (canonical) |
| [`docs/architecture-status.md`](architecture-status.md) | Full foundation architecture |
| [`docs/testing.md`](testing.md) | Smoke suites + runners |
| [`docs/dialogue-npc-system-status.md`](dialogue-npc-system-status.md) | This report |
