# AGENTS.md

## Project

MySkills is a native macOS SwiftUI app for managing agent skills.

- Private skill library: `~/.myskills/skills`
- Skills are installed/imported into MySkills first, then enabled by symlink to global or project agent paths.
- Main screens: `Library`, `Discover`, `Enabled`, `Skill Reader`, `Settings`.
- `Discover` uses skills.sh API.
- Package type: SwiftPM executable macOS app.
- Dependency: `MarkdownUI` for rendering `SKILL.md`.

## Commands

- Build: `swift build`
- Create signed app bundle: `make sign`
- Run app: `make run`
- Verify launch: `make verify`
- Clean build outputs: `make clean`

## File Map

- `Sources/MySkillsApp/MySkillsApp.swift`: app entry, windows, settings scene.
- `Sources/MySkillsApp/ContentView.swift`: sidebar and top-level navigation.
- `Sources/MySkillsApp/AppStore.swift`: app state and user actions.
- `Sources/MySkillsApp/Models.swift`: records, enums, URL formatting.
- `Sources/MySkillsApp/Services.swift`: filesystem, skills.sh API, Git import, symlinks, process helpers.
- `Sources/MySkillsApp/LibraryViews.swift`: installed skills list, details, enable sheet.
- `Sources/MySkillsApp/DiscoverView.swift`: search and Git repository browsing.
- `Sources/MySkillsApp/EnabledViews.swift`: global and project enablements.
- `Sources/MySkillsApp/SkillReaderView.swift`: rendered `SKILL.md` reader window.
- `Sources/MySkillsApp/SettingsView.swift`: folder open preferences.
- `Sources/MySkillsApp/SharedViews.swift`: shared small views.
- `Resources/Info.plist`: app bundle metadata copied by `make sign`.
- `Resources/AppIcon.icon`: Icon Composer app icon, compiled by `actool` during `make sign`.
