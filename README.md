# Bag Tooltip Fix

A small World of Warcraft addon for **WoW Forever** (interface `16001`) that fixes tooltips when you play with a gamepad in the Gamepad UI.

## The problem

In Gamepad UI, Blizzard's `GameTooltip_OnShow()` hides every tooltip while a managed window is open and the `GamepadDisableTooltips` CVar is set. That CVar is global, and several places toggle it, such as the bag RS toggle and the gamepad action bar editor. One window can leave it on, and then tooltips stay hidden everywhere.

The RS toggle that should turn it back off belongs to a `FrameControlsManager` binding group. That group is only active while the manager has a focused frame, so pressing RS often does nothing. The Professions window also shows an LS toggle prompt, but that binding has no callback.

## What the addon does

- **Owns the tooltip CVar while windows are open.** When bags or any window tracked by the gamepad `FrameControlsManager` open, the addon applies your chosen tooltip state. When the last window closes, it restores the previous value.
- **Makes RS toggle tooltips reliably.** While a window is open and you're out of combat, RS is override-bound to the addon's own toggle, so it works whatever Blizzard's focus state is. In Professions, LS does the same, matching the footer prompt.
- **Puts tooltips next to their window.** A tooltip whose owner is inside an open window (bags, gamepad-managed frames, UI panels, menus) is placed beside that window instead of over the hovered element. It goes on the left when there's room and on the right otherwise. All open bags count as one window. Tooltips from HUD elements such as action bars and unit frames are left alone, and so are tooltips from windows wider than 80% of the screen.
- **Fills empty crafted-item tooltips in Professions.** If `GameTooltip:SetRecipeResultItem()` leaves the tooltip empty, the addon shows the item from its hyperlink. If there's no hyperlink, it uses the output item ID, and as a last resort the recipe spell.
- **Adopts Blizzard's own toggle.** If Blizzard's toggle changes the CVar while a window is open, the addon saves that as your new choice.

The addon never replaces Blizzard functions. It only uses `hooksecurefunc`, `HookScript` and override bindings, so it doesn't cause taint.

## Installation

1. Download or clone this repository.
2. Copy the `BagTooltipFix` folder into your WoW Forever `Interface/AddOns/` directory.
3. Restart the game or run `/reload`, then make sure **Bag Tooltip Fix** is enabled in the AddOns list.

## Usage

| Input | Action |
| --- | --- |
| **RS** (while a window is open) | Toggle tooltips in windows on or off |
| **LS** (in Professions) | Same toggle, matching the on-screen prompt |
| `/btf` | Show the current state and the available commands |
| `/btf anchor` | Turn placing tooltips next to their window on or off (default: on) |
| `/btf show` | Force tooltips in windows back on |
| `/btf debug` | Turn debug output for the Professions recipe tooltip on or off |

Bindings can't change during combat. If a window opens or closes in combat, the RS/LS bindings update as soon as combat ends.

## Saved settings

Settings are saved per account in `BagTooltipFixDB`:

| Key | Default | Meaning |
| --- | --- | --- |
| `hideTooltips` | `false` | Whether tooltips are hidden while windows are open |
| `anchorToWindow` | `true` | Whether tooltips are placed next to their window |
| `debug` | `nil` | Debug output for the Professions recipe tooltip |

## Compatibility

- Client: WoW Forever (`## Interface: 16001`)
- Built for the Gamepad UI. The tooltip placement also works with mouse and keyboard.

## License

No license has been chosen yet.
