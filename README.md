## Set up new worksation

1. Download my [Premiere Pro shortcuts](https://raw.githubusercontent.com/lucuma13/prem/refs/heads/main/Luis_Mengo_25.1.kys):
```
curl --output-dir ~/Documents/Adobe/Premiere\ Pro/ -O "https://raw.githubusercontent.com/lucuma13/prem/refs/heads/main/Luis_Mengo_25.1.kys:"
```

2. Change default shell to bash:
```
chsh -sh /bin/bash
```

3. Install Homebrew:
```
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
```

4. Install useful formulas and casks:
```
brew tap lucuma13/homebrew-dit
brew install git media-info exiftool ffmpeg atomicparsley bento4 imagemagick wget lookback
brew install --cask google-chrome vlc audacity mediainfo mediahuman-audio-converter appcleaner
```

5. Download and install Pro Video Formats:
```
cd ~/Downloads && curl -O "https://updates.cdn-apple.com/2026/macos/072-84099-20260127-5022F0FE-82CF-44E9-B96D-430E73501EBA/ProVideoFormats.dmg"
```
```
hdiutil attach ~/Downloads/ProVideoFormats.dmg
sudo installer -pkg /Volumes/ProVideoFormats/ProVideoFormats.pkg -target /
```
```
hdiutil detach /Volumes/ProVideoFormats && rm ~/Downloads/ProVideoFormats.dmg
```
