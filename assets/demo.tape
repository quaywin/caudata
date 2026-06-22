# VHS Tape config for Caudata
# Generate with: vhs demo.tape

# Output path
Output assets/demo.gif

# Terminal Settings
Set FontSize 14
Set Width 1200
Set Height 600
Set Padding 15
Set Theme "Catppuccin Macchiato"
Set PlaybackSpeed 1.0

# Start command
Type "caudata"
Enter
Sleep 3s

# Navigate down to the second server
Down 1
Sleep 1s

# Press tab to switch focus to the container list
Tab
Sleep 3s

# Navigate down the container list 5 times with 2-second delays
Down 1
Sleep 3s
Down 1
Sleep 3s
Down 1
Sleep 3s
Down 1
Sleep 5s

# Quit
Type "q"
Sleep 1s
