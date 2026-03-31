Set Width 1200
Set Height 800
Set FontSize 13
Set Shell "bash"
Set TypingSpeed 0
Set Padding 0

# Start driver in background, then attach to demo session
Hide
Type "bash demo/driver.sh &"
Enter
Sleep 0.5s
Type "AMUX_SESSION=amux-demo amux attach"
Enter
Sleep 2s
Show

# Total demo: ~38s visible (driver runs ~40s total)
Sleep 42s
