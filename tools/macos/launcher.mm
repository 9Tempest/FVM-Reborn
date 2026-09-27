// Launch the unchanged GameMaker runner with the same path normalization it
// uses for bundle file lookup. On a translocated app NSBundle can return
// /private/var/... while NSString standardizes an existing path to /var/....
// Runtime 2026.0.0.23 compares these paths before reading options.ini, and
// crashes on a null IniFile when the different prefixes hide that file.
#import <Foundation/Foundation.h>

#include <cerrno>
#include <cstdio>
#include <cstring>
#include <unistd.h>
#include <vector>

int main(int argc, char **argv) {
  @autoreleasepool {
    NSBundle *bundle = [NSBundle mainBundle];
    NSString *game = [[[bundle resourcePath]
      stringByAppendingPathComponent:@"game.ios"] stringByStandardizingPath];
    NSString *options = [[game stringByDeletingLastPathComponent]
      stringByAppendingPathComponent:@"options.ini"];
    NSString *runner = [[bundle bundlePath]
      stringByAppendingPathComponent:@"Contents/MacOS/Mac_Runner"];
    NSFileManager *files = [NSFileManager defaultManager];
    if (!game || !runner || ![files isReadableFileAtPath:game] ||
        ![files isReadableFileAtPath:options] || ![files isExecutableFileAtPath:runner]) {
      std::fputs("FVM Reborn: the app is incomplete; game.ios, options.ini or Mac_Runner is missing.\n", stderr);
      return 78;
    }

    // No shell, chdir, environment changes, or background child process.
    // The runner quotes argv itself; adding quotes here would corrupt spaces.
    // Append -game so the bundled game wins while all original arguments keep
    // their positions (including the co-op test runner's host/guest arguments).
    std::vector<char *> arguments;
    arguments.reserve(static_cast<size_t>(argc) + 3);
    arguments.push_back(const_cast<char *>([runner fileSystemRepresentation]));
    for (int i = 1; i < argc; ++i) arguments.push_back(argv[i]);
    arguments.push_back(const_cast<char *>("-game"));
    arguments.push_back(const_cast<char *>([game UTF8String]));
    arguments.push_back(nullptr);
    execv(arguments[0], arguments.data());
    const int error = errno;
    std::fprintf(stderr, "FVM Reborn: could not start Mac_Runner: %s\n", std::strerror(error));
    return 71;
  }
}
