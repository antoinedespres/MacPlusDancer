# MacPlusDancer

https://github.com/user-attachments/assets/c960a018-b9ec-44f9-b971-cfde95a512fb

A fork of [samhenrigold/MacPlusDancer](https://github.com/samhenrigold/MacPlusDancer)
by [Sam Gold](https://github.com/samhenrigold), who wrote the original app. This fork
adds one thing: the dancer can follow your running Claude Code sessions, dancing while
Claude works and stopping when it finishes or needs you. See
[Claude Code sync](#claude-code-sync).

Original product description [from 2003](https://web.archive.org/web/20040610092815/http://www.microsoft.com/windows/Plus/dme/music.asp#dancer):
> Your desktop becomes a virtual dance floor as amazingly lifelike, 3-D figures dance to the beat of your favorite tunes. Choose from a variety of dancers and dance styles, including hip-hop, disco, salsa, and more.
> 
> Get to know Amanda, Cobey, and all the other Plus! dancers by reading their bios online, and then download more of your favorite dancers to your computer.


MacPlusDancer is a delightfully nostalgic macOS app that brings back the dancers from Microsoft Plus! (their exclamation point, not mine).

- Choose from a variety of dancers with different styles
- Drag and position dancers anywhere on your screen
- Dancers stay on top of other windows for maximum visibility
- Toggle dancing on and off (except for Seth, he must dance forever)
- Or hand the toggle to Claude Code and let your sessions drive it

## Installation and Usage

The Claude Code sync is only in this fork, so build it from source:

1. Open `MacPlusDancer.xcodeproj` in Xcode and run it. The project carries the original
   author's team id, so set your own under Signing & Capabilities first.
2. Select a dancer from the menu bar icon (a dancing figure).
3. Position your dancer by dragging them around the screen.
4. Optionally turn on **Follow Claude Code** in the same menu.

For the original app without the Claude Code sync, grab a build from the
[upstream releases](https://github.com/samhenrigold/MacPlusDancer/releases) page.

## Claude Code sync

The dancer can follow your local Claude Code sessions. Turn on **Follow Claude Code**
in the menu bar and the dancer will:

- dance while at least one session is working, including while a tool you just
  approved is still running
- stop when every session has finished its turn, or is parked at an empty prompt
- stop while a session is waiting on you
- stop when you interrupt a turn with Esc

Two of those have no event behind them, so they are read off a clock instead.

Answering a permission prompt fires no hook, so the dancer stops for 20 seconds and
then assumes you approved it and that the tool is now running. That assumption expires
like any other running tool, so a prompt you walk away from does not dance forever. A
question, a plan to approve or an MCP elicitation is bracketed by real events, so the
dancer stops for exactly as long as it is on screen.

Pressing Esc fires no hook either, not even the idle notification. It does leave a
`[Request interrupted by user]` entry in the session transcript, though, and a
transcript is otherwise untouched for as long as a tool runs. So a transcript that has
grown since the last hook means the turn ended without anyone saying so, which catches
an Esc during a long tool on the next poll.

Interrupts too close to the last hook to tell apart from a tool finishing normally fall
back to a timeout. While Claude is thinking or streaming it emits `MessageDisplay`
about once a second, so 15 seconds of silence is taken to mean the turn is over. A tool
in flight emits nothing at all, so silence during one is only suspicious after 10
minutes. All three numbers are constants at the top of `ClaudeSessionMonitor`.

Enabling the toggle installs a small hook script at `~/.claude/macplusdancer/hook.sh`
and registers it in `~/.claude/settings.json`. Your existing settings and hooks are
kept, and the original file is copied to `settings.json.macplusdancer-backup` the first
time the app writes to it. Each session reports its state to a file in
`~/.claude/macplusdancer/sessions/`, which is all the app reads. A newer build of the
app rewrites hooks left by an older one on launch.

Every session counts, including ones running under an IDE extension rather than in a
terminal, so the dancer keeps going while any window anywhere is busy.

Turning the toggle off removes both the hook entries and the script. Sessions that were
already running when you enabled it may need to be restarted before they start
reporting. Files left behind by a session that was killed outright are cleaned up once
its process is gone.

While Claude Code is driving, it also outranks Seth. He is still not permitted to stop
dancing by hand.

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

_NOTE: If you submit a PR to make Seth stop dancing, it will be rejected._

## Legal Note

The dancer animations are from the original Microsoft Plus 2003 application. This project is not affiliated with or endorsed by Microsoft. It's a fan-made port created for educational and nostalgic purposes.

## Credits

MacPlusDancer was created by [Sam Gold](https://github.com/samhenrigold) at
[samhenrigold/MacPlusDancer](https://github.com/samhenrigold/MacPlusDancer). Everything
here except the Claude Code sync is his work.

[This website](http://jfsworld.net/plus_dancers.htm) from the early 2000s was very useful in building this app. Shoutout to whoever made that website, I suppose.

## FAQ

**Q: Why should I use this?**

You should not.

**Q: Why can't I make Seth stop dancing?**

We cannot legally answer that.

**Q: Why is this app so big?**

This app is 52 video files in a trench coat.

**Q: Is there dancer lore?**

[Yes.](https://web.archive.org/web/20040609192145/http://www.microsoft.com/windows/plus/dme_more/moredancers.asp)

**Q: Does Seth stop dancing when Claude Code stops?**

Yes. This is the one indignity he must suffer.
