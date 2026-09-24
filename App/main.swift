import LocalBoardUI

// The single entry point, shared by both build paths: the Xcode app target
// compiles this file, and so does the `LocalBoardApp` SwiftPM target used by
// Scripts/bundle-spm.sh. Keeping one file means the two cannot drift.
LocalBoardScene.main()
