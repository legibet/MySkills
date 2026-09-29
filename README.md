# MySkills

MySkills is a native macOS app for managing agent skills across agents and projects. It keeps skills in a central library at `~/.myskills/skills` and enables them where needed using symbolic links. Skills can be added from [skills.sh](https://skills.sh), Git repositories, or local folders.

## Install

The prebuilt app requires macOS 26 or later and an Apple Silicon Mac.

Download [MySkills.dmg](../../releases/latest). The app is not notarized, so remove the quarantine attribute before the first launch:

```sh
xattr -dr com.apple.quarantine /Applications/MySkills.app
```

## Build from source

Xcode Command Line Tools are required.

```sh
swift build
```

To create `dist/MySkills.dmg`:

```sh
make dmg
```

## License

[MIT](LICENSE)
