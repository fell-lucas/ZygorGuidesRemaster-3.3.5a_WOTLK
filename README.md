# Zygor Guides Viewer Remaster

Remastered Zygor Guides Viewer for **World of Warcraft: Wrath of the Lich King (WotLK) 3.3.5a (build 12340)**.

A remastered version of the classic Zygor Guides Viewer, updated for WotLK 3.3.5a private servers with a cleaner UI and maintained compatibility.

This project keeps the classic Zygor workflow while delivering a cleaner remastered presentation and active upkeep for the 3.3.5a community.

[![Download](https://img.shields.io/badge/Download-Addon-2ea043?style=for-the-badge&labelColor=555555)](https://github.com/ErebusAres/ZygorGuidesRemaster-3.3.5a_WOTLK/archive/refs/heads/main.zip)
[![Install](https://img.shields.io/badge/Install-Quickly-8250df?style=for-the-badge&labelColor=555555)](#-quick-install)
[![Help](https://img.shields.io/badge/Help-Localize-f0883e?style=for-the-badge&labelColor=555555)](#-support-wanted-localization-qa)
[![Safety](https://img.shields.io/badge/Safety-VirusTotal_Report-1f6feb?style=for-the-badge&labelColor=555555)](https://www.virustotal.com/gui/url/d55dfec1532a98b39fc87a1a4f34c06b644de5988b24288bf207610b0c1b46fa/detection)

![Guides Included](https://img.shields.io/badge/Guides-Included-orange) ![Last Commit](https://img.shields.io/github/last-commit/ErebusAres/ZygorGuidesRemaster-3.3.5a_WOTLK?label=Updated&color=brightgreen) ![WoW Compatible](https://img.shields.io/badge/For-WoW-yellow) ![Era WotLK 3.3.5a](https://img.shields.io/badge/Era-WotLK_3.3.5a-blue)

[![ko-fi](https://ko-fi.com/img/githubbutton_sm.svg)](https://ko-fi.com/T6T01U9GMM)

## Version

- Version: ![Version](https://img.shields.io/github/commit-activity/t/ErebusAres/ZygorGuidesRemaster-3.3.5a_WOTLK?label=Version%203.0.&color=1f6feb)
- Intended client: **WotLK 3.3.5a / 12340**

## Who This Is For

This addon is intended for:

- World of Warcraft **WotLK 3.3.5a (build 12340)** clients
- Private server environments (for example TrinityCore-based servers)
- Players who want the classic Zygor guide experience with a cleaner UI

This project is primarily focused on **WotLK 3.3.5a**. Other clients may work, but support and testing are centered on 3.3.5a.

## What You Get

- Step-by-step leveling and quest progression guidance.
- Arrow and waypoint navigation while you play.
- Structured objective flow (accept, complete, and turn-in).
- A cleaner, more readable viewer UI designed for long play sessions.
- Includes talent guidance via the bundled `ZygorTalentAdvisor` module inside `ZygorGuidesViewerRM`.

## What Stayed the Same

Core 3.3.5a-era behavior is preserved:

- Guide parser and step engine.
- Map and waypoint workflow.
- Legacy guide execution patterns.
- Base `ZygorTalentAdvisor` behavior and structure.

## What's New in the Remaster

- Cleaner, retail-inspired UI shell for both guide browsing and options.
- New standalone Guide Manager (Home / Featured / Current / Recent) with category sidebar, search, favorites, and folder-style tree behavior.
- New in-app Options experience with categorized navigation, searchable pages, and improved layout consistency.
- Remastered waypoint arrow and objective text styling updates, including clearer action/title/distance presentation and distance color gradients.
- Accessibility improvements including colorblind presets and simplified noun-color handling for better readability.
- Ongoing compatibility focus for 3.3.5a environments and expanded guide coverage where applicable.

## Included Components

1. `ZygorGuidesViewerRM` - Remastered viewer and guide runtime.
2. `ZygorTalentAdvisor` - bundled inside `ZygorGuidesViewerRM` and loaded as part of the addon package.

## Key Controls

- Minimap icon:
  - Left-click toggles the guide viewer.
  - Right-click opens the Guide Manager.
  - Shift + Right-click opens options.
- Viewer toolbar:
  - Guides left-click opens the legacy quick guide dropdown.
  - Guides right-click opens the Guide Manager.
  - Settings left-click opens quick settings.
  - Settings right-click opens Guide Manager options.

## Quick Install

### Installation Overview

1. Download the ZIP.
2. Extract to `Interface\AddOns\`.
3. Launch the game.
4. Enable the addon.

### Detailed Steps

1. Close World of Warcraft.
2. Open `%WoWFolder%\Interface\AddOns\`.
3. Remove older folders if present:
   - `ZygorGuidesViewer`
   - `ZygorTalentAdvisor`
   - This avoids mixed files from older releases.
4. Copy this folder into `AddOns`:
   - `ZygorGuidesViewerRM`
5. Confirm the top-level folder exists:
   - `Interface\AddOns\ZygorGuidesViewerRM\ZygorGuidesViewerRM.toc`
6. Launch the game and enable the addon.

## Common Issues

**Addon not showing in-game**

- Make sure the folder structure is:
  - `Interface\AddOns\ZygorGuidesViewerRM\ZygorGuidesViewerRM.toc`
- Do not nest folders (no double folder level).

**Out of date warning**

- Enable **Load out of date AddOns** on the character select screen.

**Guide not progressing**

- Some imported guides may not fully match 3.3.5a data.
- See the Known Issues section below.

## Update Notes

1. Install or update the `ZygorGuidesViewerRM` folder as a single addon package.
2. `/reload` is usually enough for Lua-only changes.
3. A full relaunch is safer when files, XML includes, assets, or bundled modules change.

## Guide Profiles

- Current default guide content is the remastered, TrinityCore-oriented profile for WotLK 3.3.5a private servers.
- An optional Alliance fallback profile exists at `Guides\Leveling_Original\ZygorGuidesAlliance.lua`.
- That fallback is original, unmodified classic Zygor content and should only be used if the remastered default route is problematic for a specific session.

## Localization

Localization key coverage is complete across shipped locales (`Main` + `NPCs`) with placeholder and format-consistency checks.

Current focus is community QA review:

- natural phrasing in live gameplay context,
- terminology consistency,
- official localized NPC proper names,
- encoding and readability verification.

Localization was largely AI-assisted and should be treated as needing community review until native-speaker QA confirms quality.

### Community Credits

- [`mikki33`](https://github.com/mikki33) for providing Russian localization changes and review updates.

## Support Wanted (Localization QA)

If you can validate translations in-game, your help is very welcome.

Please report:

- mistranslations,
- awkward phrasing,
- broken placeholders (`%s`, `%d`, `|n`, color codes),
- incorrect NPC names,
- encoding artifacts.

## Safety and Trust

This addon is fully open source and can be inspected before use.

- [![VirusTotal Report](https://img.shields.io/badge/VirusTotal-View_Report-3bb143?style=flat-square)](https://www.virustotal.com/gui/url/d55dfec1532a98b39fc87a1a4f34c06b644de5988b24288bf207610b0c1b46fa/detection)
- You can review all files and changes directly in this repository.
- A VirusTotal scan of the download link is provided for transparency.

## Changelog

### Revision 172 - 3.0.172

- Fixed Gear Finder empty result rows so internal `reject:` diagnostics no longer appear under `No upgrade found`.
- Prevented Gear Finder from recommending an exact item already equipped in a ring or trinket paired slot.
- Updated addon version metadata to 3.0.172.

### Revision 171 - 3.0.171

- Reduced built-in waypoint arrow garbage generation by separating arrow direction updates from distance/title/ETA text refreshes.
- Added guards so unchanged arrow labels are not repeatedly rewritten, reused fallback color tables in the arrow update path, and fixed ETA averaging when no speed samples are available.
- Added arrow optimization controls: 10 FPS arrow refresh, separate Arrow Text Refresh cadence, and an Animated Arrow Pulse toggle for lower per-frame visual work.
- Updated addon version metadata to 3.0.171.

### Revision 170 - 3.0.170

- Fixed `|only if not Orc Warlock`-style race/class guide conditions so they route through the requirement matcher instead of producing invalid Lua. Thanks to Hypopheria for the report and test guide notes.
- Fixed minimap waypoint update crashes when marker frames lose their waypoint during an update, and guarded Astrolabe minimap diameter lookup against custom indoor/zoom states.
- Added a Talent Advisor enable toggle, hid the talent-tab advisor button when disabled, restored the button when enabled, and expanded the suggestion scroll area for larger unspent-talent batches.
- Fixed the Gear Advisor character-screen Z button so disabling Gear Advisor hides the PaperDoll button and prevents the finder from opening.
- Applied apesquatch's guide/runtime fixes from PRs #43-#48: class-defining `|noobsolete` quest tags, quest-chain corrections, Razor Hill envelope/key tag updates, guide metadata hoisting, and `Goal:IsFitting()` returning `self.wrong` state correctly.
- Updated addon version metadata to 3.0.170.

### Revision 169 - 3.0.169

- Added an off-by-default Gear Finder `Prefer tier progression` mode that keeps the default best-path ranking unchanged unless enabled.
- Tier progression now prefers base WotLK dungeon/heroic progression, treats Trial of the Champion, Forge of Souls, Pit of Saron, and Halls of Reflection as catch-up 5-mans, and falls forward per slot only when no upgrade exists in the current progression band.
- Excluded raid-crafted items from tier-progression recommendations while preserving them for the default best-path mode.
- Added race-mask validation from `ZygorItemDB.lua` so Gear Finder rejects race-locked items the current character cannot equip.
- Updated addon version metadata to 3.0.169.

### Revision 168 - 3.0.168

- Added 76 additional missing item database records from `check_result (1).md` after verifying each item ID/name against WotLKDB.
- Re-sorted `ZygorItemDB.lua` after the import by item level descending and item ID ascending, keeping the item database mechanically ordered.
- Updated `ZygorItemDB.lua` metadata to `2026-05-13 12:15:18 -05:00` and `25183 Items`.
- Updated addon version metadata to 3.0.168.

### Revision 167 - 3.0.167

- Added 170 missing low-level item records from the latest item database check result after verifying each item ID/name against WotLKDB.
- Re-sorted `ZygorItemDB.lua` by item level descending and item ID ascending within each item level for easier review and future maintenance.
- Updated `ZygorItemDB.lua` metadata to `2026-05-13 10:21:00 -05:00` and `25107 Items`.
- Updated addon version metadata to 3.0.167.

### Revision 166 - 3.0.166

- Added a ChromieCraft compatibility guard for `QuestPOI_HideButtons` so missing Blizzard POI button globals no longer crash Astrolabe-driven map marker placement.
- Added LibRover compatibility shims for partial `C_Map` tables that omit `GetBestMapForUnit` or `GetPlayerMapPosition` on 3.3.5a clients.
- Updated addon version metadata to 3.0.166.

### Revision 165 - 3.0.165

- Fixed a combat-lockdown blocked action error where the floating action button bar could call protected `Hide()` paths while entering combat.
- Added missing item database records for `23478` Recruit's Pants, `23479` Recruit's Robe, `1374` Frayed Shoes, and `2650` Flimsy Chain Boots.
- Updated `ZygorItemDB.lua` metadata to `2026-05-13 09:12:38 -05:00` and `24937 Items`.
- Updated addon version metadata to 3.0.165.

## Notes

- Intended target client is **WotLK 3.3.5a (12340)**.
- It may work on other versions, but compatibility is not guaranteed.
- `ZygorTalentAdvisor` is bundled and loaded from within `ZygorGuidesViewerRM`.

## Known Issues

- Arrow scale/position drift:
  - On some setups, changing Waypoint Arrow Scale can shift the arrow position unexpectedly.
  - Resetting arrow position may not fully normalize the anchor in all UI/minimap addon combinations.
  - Status: deferred for now.

- Some imported guides may be incomplete or not fully aligned to 3.3.5a data.
- If a guide behaves incorrectly, disable it in `ZygorGuidesViewerRM/Guides/Autoload.xml` and report it.

## Q&A

**Is this remaster free?**

Yes. This remastered version is and will remain free.

**Where should I download it from?**

Use the main repository download link in this README.

**Are third-party mirrors or repacks safe?**

Not always. Use other sites/downloads at your own risk.

## Credits

Original Zygor Guides concept and content belong to the original creators.

This remaster focuses on UI/UX modernization, packaging quality, compatibility maintenance, and localization completion for the 3.3.5a player community.

## Example Images

### New Guide + Options Menus

![options menu display](docs/images/options-menu-display.png)
![guide manager selection preview](docs/images/guide-manager-selection-preview.png)
<img width="1248" height="845" alt="image" src="https://github.com/user-attachments/assets/6d66d7d6-67bc-4c52-bbb5-5cea38e5bbde" />

### New Pointer Arrow

![new pointer arrow](docs/images/new-arrow.gif)

### ... With Colorblind Options

![colorblind deuteran](docs/images/new-arrow-deuteran.gif)
![colorblind protan](docs/images/new-arrow-protan.gif)
![colorblind tritan](docs/images/new-arrow-tritan.gif)

### New And Legacy Looks

<img width="436" height="264" alt="Viewer Step Flow" src="https://github.com/user-attachments/assets/f0dddbf0-7bfa-4b95-a250-0692c7690921" />
<img width="586" height="260" alt="Guide Window Layout" src="https://github.com/user-attachments/assets/e6b85c9c-8835-4e49-96b1-608ad9944b0f" />
<img width="637" height="197" alt="Waypoint and Route Display" src="https://github.com/user-attachments/assets/cd258eb1-ebb6-420d-9516-4abe9d75d88c" />
<img width="443" height="687" alt="Talent Advisor Panel" src="https://github.com/user-attachments/assets/b3f2c2ef-2bef-4ca4-b033-37c314b151d5" />

### New Route and Loop guide modes

<img width="433" height="247" alt="image" src="https://github.com/user-attachments/assets/579b6acb-df5e-4f40-8ef3-7d6b33e1015d" />
<img width="436" height="248" alt="image" src="https://github.com/user-attachments/assets/a845b881-2831-43e3-bd26-5287f9783d68" />






























