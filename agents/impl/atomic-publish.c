#define _GNU_SOURCE

#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <linux/fs.h>
#include <linux/openat2.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/random.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

extern char **environ;

enum exit_code {
    EXIT_USAGE = 2,
    EXIT_DIRECTORY = 3,
    EXIT_CONFLICT = 4,
    EXIT_SYSCALL = 5,
    EXIT_AMBIGUOUS = 6,
};

struct identity {
    bool missing;
    char type;
    dev_t device;
    ino_t inode;
    uid_t owner;
    mode_t mode;
    nlink_t links;
    char *target;
};

struct directory_pair {
    int source;
    int destination;
    bool shared;
};

struct directory_boundary {
    const char *source_path;
    const char *source_expected;
    const char *destination_path;
    const char *destination_expected;
    bool require_paths;
};

static void close_directory_pair(struct directory_pair *pair);

static void free_identity(struct identity *identity) {
    free(identity->target);
    identity->target = NULL;
}

static bool valid_basename(const char *name) {
    return name[0] != '\0' && strcmp(name, ".") != 0 && strcmp(name, "..") != 0 &&
           strchr(name, '/') == NULL;
}

static bool safe_directory_status(const struct stat *status) {
    return S_ISDIR(status->st_mode) && status->st_uid == getuid() &&
           (status->st_mode & 0022) == 0;
}

static void identity_from_status(const struct stat *status, struct identity *identity) {
    memset(identity, 0, sizeof(*identity));
    identity->device = status->st_dev;
    identity->inode = status->st_ino;
    identity->owner = status->st_uid;
    identity->mode = status->st_mode & 07777;
    identity->links = status->st_nlink;
    if (S_ISREG(status->st_mode)) {
        identity->type = 'f';
    } else if (S_ISDIR(status->st_mode)) {
        identity->type = 'd';
    } else if (S_ISLNK(status->st_mode)) {
        identity->type = 'l';
    } else {
        identity->type = 's';
    }
}

static bool same_status_identity(const struct stat *left, const struct stat *right) {
    return left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
           left->st_uid == right->st_uid && left->st_mode == right->st_mode &&
           left->st_nlink == right->st_nlink;
}

static char *read_link_target(int directory, const char *name, const struct stat *before) {
    size_t capacity = before->st_size > 0 ? (size_t)before->st_size + 1 : 256;
    char *buffer = NULL;

    while (capacity <= 65536) {
        ssize_t length;
        char *larger = realloc(buffer, capacity);
        if (larger == NULL) {
            free(buffer);
            return NULL;
        }
        buffer = larger;
        length = readlinkat(directory, name, buffer, capacity);
        if (length < 0) {
            free(buffer);
            return NULL;
        }
        if ((size_t)length < capacity) {
            buffer[length] = '\0';
            return buffer;
        }
        capacity *= 2;
    }
    free(buffer);
    errno = ENAMETOOLONG;
    return NULL;
}

static int capture_identity(int directory, const char *name, struct identity *identity) {
    struct stat before;
    struct stat after;

    memset(identity, 0, sizeof(*identity));
    if (fstatat(directory, name, &before, AT_SYMLINK_NOFOLLOW) != 0) {
        if (errno == ENOENT) {
            identity->missing = true;
            return 0;
        }
        return -1;
    }
    identity_from_status(&before, identity);
    if (identity->type == 'l') {
        identity->target = read_link_target(directory, name, &before);
        if (identity->target == NULL) {
            return -1;
        }
        if (fstatat(directory, name, &after, AT_SYMLINK_NOFOLLOW) != 0 ||
            !same_status_identity(&before, &after)) {
            free_identity(identity);
            errno = EAGAIN;
            return -1;
        }
    }
    return 0;
}

static bool same_identity(const struct identity *left, const struct identity *right) {
    if (left->missing || right->missing) {
        return left->missing == right->missing;
    }
    if (left->type != right->type || left->device != right->device || left->inode != right->inode ||
        left->owner != right->owner || left->mode != right->mode || left->links != right->links) {
        return false;
    }
    return left->type != 'l' || strcmp(left->target, right->target) == 0;
}

static char *identity_token(const struct identity *identity) {
    char *token;
    char *target_hex;
    size_t target_length;

    if (identity->missing) {
        return strdup("missing");
    }
    target_length = identity->type == 'l' ? strlen(identity->target) : 0;
    target_hex = calloc(target_length * 2 + 2, 1);
    if (target_hex == NULL) {
        return NULL;
    }
    if (identity->type == 'l') {
        for (size_t index = 0; index < target_length; index++) {
            snprintf(target_hex + index * 2, 3, "%02x", (unsigned char)identity->target[index]);
        }
    } else {
        strcpy(target_hex, "-");
    }
    if (asprintf(&token, "%c:%" PRIuMAX ":%" PRIuMAX ":%" PRIuMAX ":%04o:%" PRIuMAX ":%s",
                 identity->type, (uintmax_t)identity->device, (uintmax_t)identity->inode,
                 (uintmax_t)identity->owner, identity->mode, (uintmax_t)identity->links,
                 target_hex) < 0) {
        token = NULL;
    }
    free(target_hex);
    return token;
}

static char *directory_identity_token(const struct stat *status) {
    char *token;

    if (asprintf(&token, "D:%" PRIuMAX ":%" PRIuMAX ":%" PRIuMAX ":%04o",
                 (uintmax_t)status->st_dev, (uintmax_t)status->st_ino,
                 (uintmax_t)status->st_uid, status->st_mode & 07777) < 0) {
        return NULL;
    }
    return token;
}

static int open_directory_path(const char *path) {
    struct open_how how = {
        .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
    };

    if (path[0] != '/') {
        fprintf(stderr, "atomic-publish: directory must be absolute: %s\n", path);
        return -1;
    }
    return (int)syscall(SYS_openat2, AT_FDCWD, path, &how, sizeof(how));
}

static int validate_directory_fd(int directory, const char *label, const char *expected,
                                 bool require_cloexec) {
    struct stat status;
    char *actual;
    int flags;
    int result = 0;

    if (fstat(directory, &status) != 0 || !safe_directory_status(&status)) {
        fprintf(stderr, "atomic-publish: unsafe directory boundary: %s\n", label);
        return EXIT_DIRECTORY;
    }
    flags = fcntl(directory, F_GETFD);
    if (flags < 0 || (require_cloexec && (flags & FD_CLOEXEC) == 0)) {
        fprintf(stderr, "atomic-publish: invalid directory descriptor flags: %s\n", label);
        return EXIT_DIRECTORY;
    }
    if (expected == NULL) {
        return 0;
    }
    actual = directory_identity_token(&status);
    if (actual == NULL) {
        return EXIT_SYSCALL;
    }
    if (strcmp(actual, expected) != 0) {
        fprintf(stderr, "atomic-publish: directory identity conflict: %s\n", label);
        result = EXIT_CONFLICT;
    }
    free(actual);
    return result;
}

static int open_checked_directory(const char *path, const char *expected, int *directory) {
    int result;

    *directory = open_directory_path(path);
    if (*directory < 0) {
        fprintf(stderr, "atomic-publish: cannot safely open directory %s: %s\n", path,
                strerror(errno));
        return EXIT_DIRECTORY;
    }
    result = validate_directory_fd(*directory, path, expected, true);
    if (result != 0) {
        close(*directory);
        *directory = -1;
    }
    return result;
}

static int parse_descriptor(const char *descriptor_text, int *descriptor) {
    char *end;
    long parsed;

    errno = 0;
    parsed = strtol(descriptor_text, &end, 10);
    if (errno != 0 || end == descriptor_text || *end != '\0' || parsed < 0 ||
        parsed > INT32_MAX) {
        return EXIT_USAGE;
    }
    *descriptor = (int)parsed;
    return 0;
}

static int duplicate_checked_directory(const char *descriptor_text, const char *expected,
                                       int *directory) {
    int inherited;
    int result = parse_descriptor(descriptor_text, &inherited);

    if (result != 0) {
        return result;
    }
    *directory = fcntl(inherited, F_DUPFD_CLOEXEC, 3);
    if (*directory < 0) {
        return EXIT_DIRECTORY;
    }
    result = validate_directory_fd(*directory, descriptor_text, expected, true);
    if (result != 0) {
        close(*directory);
        *directory = -1;
    }
    return result;
}

static int capture_expected(int directory, const char *name, const char *expected,
                            struct identity *identity) {
    char *actual;
    int result;

    if (capture_identity(directory, name, identity) != 0) {
        fprintf(stderr, "atomic-publish: cannot capture identity for %s: %s\n", name,
                strerror(errno));
        return EXIT_SYSCALL;
    }
    actual = identity_token(identity);
    if (actual == NULL) {
        return EXIT_SYSCALL;
    }
    result = strcmp(actual, expected) == 0 ? 0 : EXIT_CONFLICT;
    if (result != 0) {
        fprintf(stderr, "atomic-publish: identity conflict for %s\n", name);
    }
    free(actual);
    return result;
}

static int rename_with_flags(int old_directory, const char *old_name, int new_directory,
                             const char *new_name, unsigned int flags) {
    return (int)syscall(SYS_renameat2, old_directory, old_name, new_directory, new_name, flags);
}

static int run_test_hook(const char *event, const char *source_path, const char *source_name,
                         const char *destination_path, const char *destination_name) {
#ifdef DOTFILES_ATOMIC_TEST_HOOK
    pid_t child = fork();
    int status;

    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        execl(DOTFILES_ATOMIC_TEST_HOOK, DOTFILES_ATOMIC_TEST_HOOK, event, source_path, source_name,
              destination_path, destination_name, (char *)NULL);
        _exit(127);
    }
    while (waitpid(child, &status, 0) < 0) {
        if (errno != EINTR) {
            return -1;
        }
    }
    if (!WIFEXITED(status)) {
        return -1;
    }
    return WEXITSTATUS(status);
#else
    (void)event;
    (void)source_path;
    (void)source_name;
    (void)destination_path;
    (void)destination_name;
    return 0;
#endif
}

static int open_directory_pair(const char *source_path, const char *source_expected,
                               const char *destination_path, const char *destination_expected,
                               const char *source_name, const char *destination_name,
                               struct directory_pair *pair) {
    int hook_status;
    int result;

    pair->source = -1;
    pair->destination = -1;
    pair->shared = false;
    result = open_checked_directory(source_path, source_expected, &pair->source);
    if (result != 0) {
        return result;
    }
    if (strcmp(source_path, destination_path) == 0) {
        if (strcmp(source_expected, destination_expected) != 0) {
            close(pair->source);
            pair->source = -1;
            return EXIT_CONFLICT;
        }
        pair->destination = pair->source;
        pair->shared = true;
    } else {
        result = open_checked_directory(destination_path, destination_expected, &pair->destination);
        if (result != 0) {
            close(pair->source);
            pair->source = -1;
            return result;
        }
    }
    hook_status = run_test_hook("after-open-directories", source_path, source_name,
                                destination_path, destination_name);
    if (hook_status != 0) {
        close_directory_pair(pair);
        return EXIT_SYSCALL;
    }
    return 0;
}

static void close_directory_pair(struct directory_pair *pair) {
    if (!pair->shared && pair->destination >= 0) {
        close(pair->destination);
    }
    if (pair->source >= 0) {
        close(pair->source);
    }
}

static int open_directory_pair_fd(const char *source_descriptor, const char *source_expected,
                                  const char *destination_descriptor,
                                  const char *destination_expected,
                                  const char *source_name, const char *destination_name,
                                  struct directory_pair *pair) {
    int hook_status;
    int result;

    pair->source = -1;
    pair->destination = -1;
    pair->shared = false;
    result = duplicate_checked_directory(source_descriptor, source_expected, &pair->source);
    if (result != 0) {
        return result;
    }
    if (strcmp(source_descriptor, destination_descriptor) == 0) {
        if (strcmp(source_expected, destination_expected) != 0) {
            close_directory_pair(pair);
            return EXIT_CONFLICT;
        }
        pair->destination = pair->source;
        pair->shared = true;
    } else {
        result = duplicate_checked_directory(destination_descriptor, destination_expected,
                                             &pair->destination);
        if (result != 0) {
            close_directory_pair(pair);
            return result;
        }
    }
    hook_status = run_test_hook("after-open-directories", source_descriptor, source_name,
                                destination_descriptor, destination_name);
    if (hook_status != 0) {
        close_directory_pair(pair);
        return EXIT_SYSCALL;
    }
    return 0;
}

static bool directory_path_matches(const char *path, const char *expected) {
    int directory = -1;
    int result = open_checked_directory(path, expected, &directory);

    if (directory >= 0) {
        close(directory);
    }
    return result == 0;
}

static bool directory_pair_paths_match(const char *source_path, const char *source_expected,
                                       const char *destination_path,
                                       const char *destination_expected) {
    if (!directory_path_matches(source_path, source_expected)) {
        return false;
    }
    return strcmp(source_path, destination_path) == 0 ||
           directory_path_matches(destination_path, destination_expected);
}

static bool directory_pair_boundaries_match(const struct directory_pair *pair,
                                            const struct directory_boundary *boundary) {
    if (validate_directory_fd(pair->source, "source", boundary->source_expected, true) != 0) {
        return false;
    }
    if (!pair->shared &&
        validate_directory_fd(pair->destination, "destination",
                              boundary->destination_expected, true) != 0) {
        return false;
    }
    return !boundary->require_paths ||
           directory_pair_paths_match(boundary->source_path, boundary->source_expected,
                                      boundary->destination_path,
                                      boundary->destination_expected);
}

static int command_directory_identity(const char *directory_path) {
    struct stat status;
    char *token;
    int directory = -1;
    int result = open_checked_directory(directory_path, NULL, &directory);

    if (result != 0) {
        return result;
    }
    if (fstat(directory, &status) != 0) {
        close(directory);
        return EXIT_SYSCALL;
    }
    token = directory_identity_token(&status);
    close(directory);
    if (token == NULL) {
        return EXIT_SYSCALL;
    }
    puts(token);
    free(token);
    return 0;
}

static int command_directory_identity_fd(const char *descriptor_text) {
    struct stat status;
    char *end;
    char *token;
    long parsed;
    int descriptor;
    int result;

    errno = 0;
    parsed = strtol(descriptor_text, &end, 10);
    if (errno != 0 || end == descriptor_text || *end != '\0' || parsed < 0 || parsed > INT32_MAX) {
        return EXIT_USAGE;
    }
    descriptor = (int)parsed;
    result = validate_directory_fd(descriptor, descriptor_text, NULL, false);
    if (result != 0) {
        return result;
    }
    if (fstat(descriptor, &status) != 0) {
        return EXIT_SYSCALL;
    }
    token = directory_identity_token(&status);
    if (token == NULL) {
        return EXIT_SYSCALL;
    }
    puts(token);
    free(token);
    return 0;
}

static int command_identity(const char *directory_path, const char *directory_expected,
                            const char *name) {
    struct identity identity = {0};
    char *token;
    int directory = -1;
    int result;

    if (!valid_basename(name)) {
        return EXIT_USAGE;
    }
    result = open_checked_directory(directory_path, directory_expected, &directory);
    if (result != 0) {
        return result;
    }
    if (capture_identity(directory, name, &identity) != 0) {
        close(directory);
        return EXIT_SYSCALL;
    }
    token = identity_token(&identity);
    free_identity(&identity);
    close(directory);
    if (token == NULL) {
        return EXIT_SYSCALL;
    }
    puts(token);
    free(token);
    return 0;
}

static int command_identity_fd(const char *descriptor_text, const char *directory_expected,
                               const char *name) {
    struct identity identity = {0};
    char *token;
    int directory = -1;
    int result;

    if (!valid_basename(name)) {
        return EXIT_USAGE;
    }
    result = duplicate_checked_directory(descriptor_text, directory_expected, &directory);
    if (result != 0) {
        return result;
    }
    if (capture_identity(directory, name, &identity) != 0) {
        close(directory);
        return EXIT_SYSCALL;
    }
    token = identity_token(&identity);
    free_identity(&identity);
    close(directory);
    if (token == NULL) {
        return EXIT_SYSCALL;
    }
    puts(token);
    free(token);
    return 0;
}

static int move_noreplace_opened(struct directory_pair *directories,
                                 const struct directory_boundary *boundary,
                                 const char *source_name, const char *destination_name,
                                 const char *expected_source) {
    struct identity source_before = {0};
    struct identity destination_before = {0};
    struct identity source_after = {0};
    struct identity destination_after = {0};
    struct identity source_stable = {0};
    struct identity destination_stable = {0};
    struct identity source_restored = {0};
    struct identity destination_restored = {0};
    int result;

    result = capture_expected(directories->source, source_name, expected_source, &source_before);
    if (result != 0 || source_before.missing) {
        result = result == 0 ? EXIT_CONFLICT : result;
        goto done;
    }
    if (capture_identity(directories->destination, destination_name, &destination_before) != 0) {
        result = EXIT_SYSCALL;
        goto done;
    }
    if (!destination_before.missing) {
        result = EXIT_CONFLICT;
        goto done;
    }
    if (rename_with_flags(directories->source, source_name, directories->destination,
                          destination_name, RENAME_NOREPLACE) != 0) {
        result = errno == EEXIST || errno == ENOENT ? EXIT_CONFLICT : EXIT_SYSCALL;
        goto done;
    }
    if (capture_identity(directories->source, source_name, &source_after) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_after) != 0) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (source_after.missing && same_identity(&destination_after, &source_before) &&
        directory_pair_boundaries_match(directories, boundary)) {
        result = 0;
        goto done;
    }
    if (capture_identity(directories->source, source_name, &source_stable) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_stable) != 0 ||
        !same_identity(&source_after, &source_stable) ||
        !same_identity(&destination_after, &destination_stable) || !source_stable.missing ||
        destination_stable.missing) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (rename_with_flags(directories->destination, destination_name, directories->source,
                          source_name, RENAME_NOREPLACE) != 0 ||
        capture_identity(directories->source, source_name, &source_restored) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_restored) != 0 ||
        !same_identity(&source_restored, &destination_stable) || !destination_restored.missing) {
        result = EXIT_AMBIGUOUS;
    } else {
        result = EXIT_CONFLICT;
    }
done:
    free_identity(&source_before);
    free_identity(&destination_before);
    free_identity(&source_after);
    free_identity(&destination_after);
    free_identity(&source_stable);
    free_identity(&destination_stable);
    free_identity(&source_restored);
    free_identity(&destination_restored);
    return result;
}

static int command_move_noreplace(const char *source_path, const char *source_expected_directory,
                                  const char *source_name, const char *destination_path,
                                  const char *destination_expected_directory,
                                  const char *destination_name, const char *expected_source) {
    struct directory_pair directories;
    struct directory_boundary boundary = {
        .source_path = source_path,
        .source_expected = source_expected_directory,
        .destination_path = destination_path,
        .destination_expected = destination_expected_directory,
        .require_paths = true,
    };
    int result;

    if (!valid_basename(source_name) || !valid_basename(destination_name)) {
        return EXIT_USAGE;
    }
    result = open_directory_pair(source_path, source_expected_directory, destination_path,
                                 destination_expected_directory, source_name, destination_name,
                                 &directories);
    if (result == 0) {
        result = move_noreplace_opened(&directories, &boundary, source_name, destination_name,
                                       expected_source);
        close_directory_pair(&directories);
    }
    return result;
}

static int command_move_noreplace_fd(const char *source_descriptor,
                                     const char *source_expected_directory,
                                     const char *source_name, const char *destination_descriptor,
                                     const char *destination_expected_directory,
                                     const char *destination_name, const char *expected_source) {
    struct directory_pair directories;
    struct directory_boundary boundary = {
        .source_path = source_descriptor,
        .source_expected = source_expected_directory,
        .destination_path = destination_descriptor,
        .destination_expected = destination_expected_directory,
        .require_paths = false,
    };
    int result;

    if (!valid_basename(source_name) || !valid_basename(destination_name)) {
        return EXIT_USAGE;
    }
    result = open_directory_pair_fd(source_descriptor, source_expected_directory,
                                    destination_descriptor, destination_expected_directory,
                                    source_name, destination_name, &directories);
    if (result == 0) {
        result = move_noreplace_opened(&directories, &boundary, source_name, destination_name,
                                       expected_source);
        close_directory_pair(&directories);
    }
    return result;
}

static int exchange_opened(struct directory_pair *directories,
                           const struct directory_boundary *boundary, const char *source_name,
                           const char *destination_name, const char *expected_source,
                           const char *expected_destination) {
    struct identity source_before = {0};
    struct identity destination_before = {0};
    struct identity source_after = {0};
    struct identity destination_after = {0};
    struct identity source_stable = {0};
    struct identity destination_stable = {0};
    struct identity source_restored = {0};
    struct identity destination_restored = {0};
    bool force_mismatch = false;
    int hook_status;
    int result;

    result = capture_expected(directories->source, source_name, expected_source, &source_before);
    if (result != 0) {
        goto done;
    }
    result = capture_expected(directories->destination, destination_name, expected_destination,
                              &destination_before);
    if (result != 0) {
        goto done;
    }
    if (source_before.missing || destination_before.missing) {
        result = EXIT_CONFLICT;
        goto done;
    }
    if (rename_with_flags(directories->source, source_name, directories->destination,
                          destination_name, RENAME_EXCHANGE) != 0) {
        result = EXIT_SYSCALL;
        goto done;
    }
    hook_status = run_test_hook("after-exchange", boundary->source_path, source_name,
                                boundary->destination_path, destination_name);
    force_mismatch = hook_status == 75;
    if (hook_status != 0 && !force_mismatch) {
        force_mismatch = true;
    }
    if (capture_identity(directories->source, source_name, &source_after) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_after) != 0) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (!force_mismatch && same_identity(&source_after, &destination_before) &&
        same_identity(&destination_after, &source_before) &&
        directory_pair_boundaries_match(directories, boundary)) {
        result = 0;
        goto done;
    }
    if (capture_identity(directories->source, source_name, &source_stable) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_stable) != 0 ||
        !same_identity(&source_after, &source_stable) ||
        !same_identity(&destination_after, &destination_stable)) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (rename_with_flags(directories->source, source_name, directories->destination,
                          destination_name, RENAME_EXCHANGE) != 0 ||
        capture_identity(directories->source, source_name, &source_restored) != 0 ||
        capture_identity(directories->destination, destination_name, &destination_restored) != 0 ||
        !same_identity(&source_restored, &destination_stable) ||
        !same_identity(&destination_restored, &source_stable)) {
        result = EXIT_AMBIGUOUS;
    } else {
        result = EXIT_CONFLICT;
    }
done:
    free_identity(&source_before);
    free_identity(&destination_before);
    free_identity(&source_after);
    free_identity(&destination_after);
    free_identity(&source_stable);
    free_identity(&destination_stable);
    free_identity(&source_restored);
    free_identity(&destination_restored);
    return result;
}

static int command_exchange(const char *source_path, const char *source_expected_directory,
                            const char *source_name, const char *destination_path,
                            const char *destination_expected_directory, const char *destination_name,
                            const char *expected_source, const char *expected_destination) {
    struct directory_pair directories;
    struct directory_boundary boundary = {
        .source_path = source_path,
        .source_expected = source_expected_directory,
        .destination_path = destination_path,
        .destination_expected = destination_expected_directory,
        .require_paths = true,
    };
    int result;

    if (!valid_basename(source_name) || !valid_basename(destination_name)) {
        return EXIT_USAGE;
    }
    result = open_directory_pair(source_path, source_expected_directory, destination_path,
                                 destination_expected_directory, source_name, destination_name,
                                 &directories);
    if (result == 0) {
        result = exchange_opened(&directories, &boundary, source_name, destination_name,
                                 expected_source, expected_destination);
        close_directory_pair(&directories);
    }
    return result;
}

static int command_exchange_fd(const char *source_descriptor,
                               const char *source_expected_directory, const char *source_name,
                               const char *destination_descriptor,
                               const char *destination_expected_directory,
                               const char *destination_name, const char *expected_source,
                               const char *expected_destination) {
    struct directory_pair directories;
    struct directory_boundary boundary = {
        .source_path = source_descriptor,
        .source_expected = source_expected_directory,
        .destination_path = destination_descriptor,
        .destination_expected = destination_expected_directory,
        .require_paths = false,
    };
    int result;

    if (!valid_basename(source_name) || !valid_basename(destination_name)) {
        return EXIT_USAGE;
    }
    result = open_directory_pair_fd(source_descriptor, source_expected_directory,
                                    destination_descriptor, destination_expected_directory,
                                    source_name, destination_name, &directories);
    if (result == 0) {
        result = exchange_opened(&directories, &boundary, source_name, destination_name,
                                 expected_source, expected_destination);
        close_directory_pair(&directories);
    }
    return result;
}

static int quarantine_name(char *buffer, size_t size) {
    unsigned char random_bytes[16];
    size_t offset;

    if (getrandom(random_bytes, sizeof(random_bytes), 0) != (ssize_t)sizeof(random_bytes)) {
        return -1;
    }
    offset = (size_t)snprintf(buffer, size, ".atomic-quarantine.");
    if (offset >= size) {
        return -1;
    }
    for (size_t index = 0; index < sizeof(random_bytes); index++) {
        if (offset + 2 >= size) {
            return -1;
        }
        snprintf(buffer + offset, size - offset, "%02x", random_bytes[index]);
        offset += 2;
    }
    return 0;
}

static bool remove_exact_empty_quarantine(int parent, const char *name,
                                          const struct stat *expected) {
    struct stat path_status;

    if (fstatat(parent, name, &path_status, AT_SYMLINK_NOFOLLOW) != 0) {
        return errno == ENOENT;
    }
    if (!same_status_identity(&path_status, expected) || !S_ISDIR(path_status.st_mode) ||
        path_status.st_nlink != 2 || unlinkat(parent, name, AT_REMOVEDIR) != 0) {
        return false;
    }
    return fstatat(parent, name, &path_status, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
}

static bool remove_empty_private_quarantine(int root, const char *name, int directory,
                                            const struct stat *expected);

static int open_private_quarantine(int parent, const char *parent_label, char *name,
                                   size_t name_size, int *directory,
                                   struct stat *created_status) {
    struct open_how how = {
        .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
    };
    struct stat opened_status;
    int flags;
    int hook_status;
    int status_result;

    for (size_t attempt = 0; attempt < 16; attempt++) {
        mode_t previous_umask;
        int mkdir_status;
        int mkdir_errno;

        if (quarantine_name(name, name_size) != 0) {
            return EXIT_SYSCALL;
        }
        previous_umask = umask(0077);
        mkdir_status = mkdirat(parent, name, 0700);
        mkdir_errno = errno;
        umask(previous_umask);
        errno = mkdir_errno;
        if (mkdir_status == 0) {
            break;
        }
        if (errno != EEXIST) {
            return EXIT_SYSCALL;
        }
        if (attempt == 15) {
            return EXIT_CONFLICT;
        }
    }
    hook_status = run_test_hook("inject-quarantine-path-fstat", parent_label, name,
                                parent_label, name);
    if (hook_status == 75) {
        errno = EIO;
        status_result = -1;
    } else if (hook_status != 0) {
        return EXIT_AMBIGUOUS;
    } else {
        status_result = fstatat(parent, name, created_status, AT_SYMLINK_NOFOLLOW);
    }
    if (status_result != 0) {
        *directory = (int)syscall(SYS_openat2, parent, name, &how, sizeof(how));
        if (*directory < 0 || fstat(*directory, &opened_status) != 0 ||
            !safe_directory_status(&opened_status) ||
            (opened_status.st_mode & 07777) != 0700 || opened_status.st_nlink != 2) {
            if (*directory >= 0) {
                close(*directory);
                *directory = -1;
            }
            return EXIT_AMBIGUOUS;
        }
        if (!remove_empty_private_quarantine(parent, name, *directory, &opened_status)) {
            close(*directory);
            *directory = -1;
            return EXIT_AMBIGUOUS;
        }
        close(*directory);
        *directory = -1;
        return EXIT_SYSCALL;
    }
    if (!safe_directory_status(created_status) ||
        (created_status->st_mode & 07777) != 0700 || created_status->st_nlink != 2) {
        return EXIT_AMBIGUOUS;
    }
    hook_status = run_test_hook("before-quarantine-open", parent_label, name, parent_label, name);
    if (hook_status != 0) {
        return remove_exact_empty_quarantine(parent, name, created_status) ? EXIT_SYSCALL
                                                                          : EXIT_AMBIGUOUS;
    }
    *directory = (int)syscall(SYS_openat2, parent, name, &how, sizeof(how));
    if (*directory < 0) {
        return remove_exact_empty_quarantine(parent, name, created_status) ? EXIT_SYSCALL
                                                                          : EXIT_AMBIGUOUS;
    }
    flags = fcntl(*directory, F_GETFD);
    hook_status = run_test_hook("inject-quarantine-opened-fstat", parent_label, name,
                                parent_label, name);
    if (hook_status == 75) {
        errno = EIO;
        status_result = -1;
    } else if (hook_status != 0) {
        status_result = -1;
    } else {
        status_result = fstat(*directory, &opened_status);
    }
    if (status_result != 0 ||
        !same_status_identity(&opened_status, created_status) || flags < 0 ||
        (flags & FD_CLOEXEC) == 0) {
        close(*directory);
        *directory = -1;
        return remove_exact_empty_quarantine(parent, name, created_status) ? EXIT_SYSCALL
                                                                          : EXIT_AMBIGUOUS;
    }
    return 0;
}

static bool directory_entry_matches(int parent, const char *name, int directory,
                                    const struct stat *expected) {
    struct stat descriptor_status;
    struct stat path_status;

    return fstat(directory, &descriptor_status) == 0 &&
           fstatat(parent, name, &path_status, AT_SYMLINK_NOFOLLOW) == 0 &&
           same_status_identity(&descriptor_status, expected) &&
           same_status_identity(&path_status, expected);
}

static bool remove_empty_private_quarantine(int root, const char *name, int directory,
                                            const struct stat *expected) {
    struct stat path_status;

    if (!directory_entry_matches(root, name, directory, expected) ||
        unlinkat(root, name, AT_REMOVEDIR) != 0) {
        return false;
    }
    return fstatat(root, name, &path_status, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT;
}

static bool directory_boundary_matches(int directory,
                                       const struct directory_boundary *boundary) {
    return validate_directory_fd(directory, "source", boundary->source_expected, true) == 0 &&
           (!boundary->require_paths ||
            directory_path_matches(boundary->source_path, boundary->source_expected));
}

static int unlink_if_opened(int directory, const struct directory_boundary *boundary,
                            const char *name, const char *expected) {
    static const char quarantine_object_name[] = "object";
    struct identity before = {0};
    struct identity target_after = {0};
    struct identity quarantine_after = {0};
    struct identity target_stable = {0};
    struct identity quarantine_stable = {0};
    struct identity target_restored = {0};
    struct identity quarantine_restored = {0};
    struct stat quarantine_directory_status;
    char quarantine[80];
    int quarantine_directory = -1;
    int hook_status;
    int result;

    result = capture_expected(directory, name, expected, &before);
    if (result != 0 || before.missing || before.type == 'd') {
        result = result == 0 ? EXIT_CONFLICT : result;
        goto done;
    }
    result = open_private_quarantine(directory, boundary->source_path, quarantine,
                                     sizeof(quarantine), &quarantine_directory,
                                     &quarantine_directory_status);
    if (result != 0) {
        goto done;
    }
    hook_status = run_test_hook("before-quarantine-move", boundary->source_path, name,
                                boundary->source_path, quarantine);
    if (hook_status != 0) {
        result = remove_empty_private_quarantine(directory, quarantine,
                                                 quarantine_directory,
                                                 &quarantine_directory_status)
                     ? EXIT_SYSCALL
                     : EXIT_AMBIGUOUS;
        goto done;
    }
    if (rename_with_flags(directory, name, quarantine_directory,
                          quarantine_object_name, RENAME_NOREPLACE) != 0) {
        result = errno == EEXIST || errno == ENOENT ? EXIT_CONFLICT : EXIT_SYSCALL;
        if (!remove_empty_private_quarantine(directory, quarantine,
                                             quarantine_directory,
                                             &quarantine_directory_status)) {
            result = EXIT_AMBIGUOUS;
        }
        goto done;
    }
    if (capture_identity(directory, name, &target_after) != 0 ||
        capture_identity(quarantine_directory, quarantine_object_name, &quarantine_after) != 0) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (target_after.missing && same_identity(&quarantine_after, &before) &&
        directory_boundary_matches(directory, boundary) &&
        directory_entry_matches(directory, quarantine, quarantine_directory,
                                &quarantine_directory_status)) {
        /*
         * Cooperating installers hold the client lock.  The random private directory prevents
         * accidental name collisions, but is not a security boundary against a malicious process
         * with the same uid.  Do not add a hook, child, or pathname lookup between this exact
         * identity check and unlinkat().
         */
        if (unlinkat(quarantine_directory, quarantine_object_name, 0) != 0 ||
            capture_identity(quarantine_directory, quarantine_object_name,
                             &quarantine_restored) != 0 ||
            !quarantine_restored.missing) {
            result = EXIT_AMBIGUOUS;
        } else if (!remove_empty_private_quarantine(directory, quarantine,
                                                     quarantine_directory,
                                                     &quarantine_directory_status)) {
            result = EXIT_AMBIGUOUS;
        } else {
            result = 0;
        }
        goto done;
    }
    if (capture_identity(directory, name, &target_stable) != 0 ||
        capture_identity(quarantine_directory, quarantine_object_name, &quarantine_stable) != 0 ||
        !same_identity(&target_after, &target_stable) ||
        !same_identity(&quarantine_after, &quarantine_stable) || !target_stable.missing ||
        quarantine_stable.missing ||
        !directory_boundary_matches(directory, boundary) ||
        !directory_entry_matches(directory, quarantine, quarantine_directory,
                                 &quarantine_directory_status)) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (rename_with_flags(quarantine_directory, quarantine_object_name, directory, name,
                          RENAME_NOREPLACE) != 0 ||
        capture_identity(directory, name, &target_restored) != 0 ||
        capture_identity(quarantine_directory, quarantine_object_name, &quarantine_restored) != 0 ||
        !same_identity(&target_restored, &quarantine_stable) || !quarantine_restored.missing ||
        !remove_empty_private_quarantine(directory, quarantine,
                                         quarantine_directory, &quarantine_directory_status)) {
        result = EXIT_AMBIGUOUS;
    } else {
        result = EXIT_CONFLICT;
    }
done:
    free_identity(&before);
    free_identity(&target_after);
    free_identity(&quarantine_after);
    free_identity(&target_stable);
    free_identity(&quarantine_stable);
    free_identity(&target_restored);
    free_identity(&quarantine_restored);
    if (quarantine_directory >= 0) {
        close(quarantine_directory);
    }
    return result;
}

static int command_unlink_if(const char *directory_path, const char *directory_expected,
                             const char *name, const char *expected) {
    struct directory_boundary boundary = {
        .source_path = directory_path,
        .source_expected = directory_expected,
        .destination_path = directory_path,
        .destination_expected = directory_expected,
        .require_paths = true,
    };
    int directory = -1;
    int result;

    if (!valid_basename(name)) {
        return EXIT_USAGE;
    }
    result = open_checked_directory(directory_path, directory_expected, &directory);
    if (result == 0) {
        result = unlink_if_opened(directory, &boundary, name, expected);
        close(directory);
    }
    return result;
}

static int command_unlink_if_fd(const char *descriptor_text, const char *directory_expected,
                                const char *name, const char *expected) {
    struct directory_boundary boundary = {
        .source_path = descriptor_text,
        .source_expected = directory_expected,
        .destination_path = descriptor_text,
        .destination_expected = directory_expected,
        .require_paths = false,
    };
    int directory = -1;
    int result;

    if (!valid_basename(name)) {
        return EXIT_USAGE;
    }
    result = duplicate_checked_directory(descriptor_text, directory_expected, &directory);
    if (result == 0) {
        result = unlink_if_opened(directory, &boundary, name, expected);
        close(directory);
    }
    return result;
}

static int command_symlink_noreplace_fd(const char *descriptor_text,
                                        const char *directory_expected, const char *name,
                                        const char *target) {
    struct identity before = {0};
    struct identity after = {0};
    char *token = NULL;
    int directory = -1;
    int result;

    if (!valid_basename(name) || target[0] == '\0') {
        return EXIT_USAGE;
    }
    result = duplicate_checked_directory(descriptor_text, directory_expected, &directory);
    if (result != 0) {
        return result;
    }
    if (symlinkat(target, directory, name) != 0) {
        result = errno == EEXIST ? EXIT_CONFLICT : EXIT_SYSCALL;
        goto done;
    }
    if (capture_identity(directory, name, &before) != 0 || before.type != 'l' ||
        before.owner != getuid() || strcmp(before.target, target) != 0 ||
        capture_identity(directory, name, &after) != 0 || !same_identity(&before, &after) ||
        validate_directory_fd(directory, descriptor_text, directory_expected, true) != 0) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    token = identity_token(&before);
    if (token == NULL) {
        result = EXIT_SYSCALL;
        goto done;
    }
    puts(token);
    result = 0;
done:
    free(token);
    free_identity(&before);
    free_identity(&after);
    if (directory >= 0) {
        close(directory);
    }
    return result;
}

static bool same_directory_identity(const struct stat *left, const struct stat *right) {
    return S_ISDIR(left->st_mode) && S_ISDIR(right->st_mode) &&
           left->st_dev == right->st_dev && left->st_ino == right->st_ino &&
           left->st_uid == right->st_uid && left->st_mode == right->st_mode;
}

static int empty_owned_directory(int directory) {
    struct dirent *entry;
    DIR *stream;
    int scan_descriptor = fcntl(directory, F_DUPFD_CLOEXEC, 3);

    if (scan_descriptor < 0) {
        return -1;
    }
    stream = fdopendir(scan_descriptor);
    if (stream == NULL) {
        close(scan_descriptor);
        return -1;
    }
    errno = 0;
    while ((entry = readdir(stream)) != NULL) {
        struct stat before;

        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }
        if (fstatat(directory, entry->d_name, &before, AT_SYMLINK_NOFOLLOW) != 0 ||
            before.st_uid != getuid()) {
            closedir(stream);
            return -1;
        }
        if (S_ISDIR(before.st_mode)) {
            struct stat opened;
            int child = openat(directory, entry->d_name,
                               O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
            if (child < 0 || fstat(child, &opened) != 0 ||
                !same_status_identity(&before, &opened) || empty_owned_directory(child) != 0) {
                if (child >= 0) {
                    close(child);
                }
                closedir(stream);
                return -1;
            }
            close(child);
            if (unlinkat(directory, entry->d_name, AT_REMOVEDIR) != 0) {
                closedir(stream);
                return -1;
            }
        } else if (unlinkat(directory, entry->d_name, 0) != 0) {
            closedir(stream);
            return -1;
        }
        errno = 0;
    }
    if (errno != 0) {
        closedir(stream);
        return -1;
    }
    return closedir(stream);
}

static int command_remove_tree_fd(const char *parent_descriptor,
                                  const char *parent_expected, const char *name,
                                  const char *tree_descriptor, const char *tree_expected) {
    struct stat parent_entry_before;
    struct stat tree_before;
    struct stat parent_entry_after;
    struct stat tree_after;
    int parent = -1;
    int tree = -1;
    int result;

    if (!valid_basename(name)) {
        return EXIT_USAGE;
    }
    result = duplicate_checked_directory(parent_descriptor, parent_expected, &parent);
    if (result != 0) {
        return result;
    }
    result = duplicate_checked_directory(tree_descriptor, tree_expected, &tree);
    if (result != 0) {
        close(parent);
        return result;
    }
    if (fstatat(parent, name, &parent_entry_before, AT_SYMLINK_NOFOLLOW) != 0 ||
        fstat(tree, &tree_before) != 0 ||
        !same_directory_identity(&parent_entry_before, &tree_before)) {
        result = EXIT_CONFLICT;
        goto done;
    }
    if (empty_owned_directory(tree) != 0 ||
        fstatat(parent, name, &parent_entry_after, AT_SYMLINK_NOFOLLOW) != 0 ||
        fstat(tree, &tree_after) != 0 ||
        !same_directory_identity(&parent_entry_before, &parent_entry_after) ||
        !same_directory_identity(&tree_before, &tree_after) ||
        unlinkat(parent, name, AT_REMOVEDIR) != 0) {
        result = EXIT_AMBIGUOUS;
        goto done;
    }
    if (fstatat(parent, name, &parent_entry_after, AT_SYMLINK_NOFOLLOW) == 0 || errno != ENOENT) {
        result = EXIT_AMBIGUOUS;
    } else {
        result = 0;
    }
done:
    close(tree);
    close(parent);
    return result;
}

static bool valid_relative_path(const char *path) {
    const char *segment = path;

    if (path[0] == '\0' || path[0] == '/') {
        return false;
    }
    for (const char *cursor = path;; cursor++) {
        unsigned char character = (unsigned char)*cursor;

        if (character == '/' || character == '\0') {
            size_t length = (size_t)(cursor - segment);

            if (length == 0 || (length == 1 && segment[0] == '.') ||
                (length == 2 && segment[0] == '.' && segment[1] == '.')) {
                return false;
            }
            if (character == '\0') {
                return true;
            }
            segment = cursor + 1;
        } else if (!((character >= 'A' && character <= 'Z') ||
                     (character >= 'a' && character <= 'z') ||
                     (character >= '0' && character <= '9') || strchr("._+@%=-", character))) {
            return false;
        }
    }
}

static int set_close_on_exec(const char *descriptor_text) {
    int descriptor;
    int flags;
    int result = parse_descriptor(descriptor_text, &descriptor);

    if (result != 0) {
        return result;
    }
    flags = fcntl(descriptor, F_GETFD);
    if (flags < 0 || fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) != 0) {
        return EXIT_DIRECTORY;
    }
    return 0;
}

static int set_probe_environment(void) {
    static const struct {
        const char *name;
        const char *value;
    } variables[] = {
        {"HOME", "/proc/self/cwd/../home"},
        {"CODEX_HOME", "/proc/self/cwd/../codex-home"},
        {"XDG_CACHE_HOME", "/proc/self/cwd/../cache"},
        {"XDG_CONFIG_HOME", "/proc/self/cwd/../config"},
        {"XDG_DATA_HOME", "/proc/self/cwd/../data"},
        {"XDG_STATE_HOME", "/proc/self/cwd/../state"},
        {"TMPDIR", "/proc/self/cwd/../tmp"},
        {"PATH", "/proc/self/cwd/../../payload/bin:/proc/self/cwd/../../payload/codex-path"},
        {"PWD", "/proc/self/cwd"},
        {"LC_ALL", "C"},
        {"TERM", "dumb"},
    };

    if (clearenv() != 0) {
        return EXIT_SYSCALL;
    }
    for (size_t index = 0; index < sizeof(variables) / sizeof(variables[0]); index++) {
        if (setenv(variables[index].name, variables[index].value, 1) != 0) {
            return EXIT_SYSCALL;
        }
    }
    return 0;
}

static int command_probe_exec(int argc, char **argv) {
    struct open_how directory_how = {
        .flags = O_RDONLY | O_DIRECTORY | O_CLOEXEC,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
    };
    struct open_how executable_how = {
        /* A non-CLOEXEC O_PATH descriptor supports both ELF and shebang execveat. */
        .flags = O_PATH,
        .resolve = RESOLVE_BENEATH | RESOLVE_NO_SYMLINKS | RESOLVE_NO_MAGICLINKS,
    };
    struct stat executable_status;
    char **child_argv = NULL;
    char *entrypoint_argv0 = NULL;
    int stage = -1;
    int work = -1;
    int executable = -1;
    int separator = -1;
    int hook_status;
    int result;

    if (argc < 11 || !valid_relative_path(argv[4]) || !valid_relative_path(argv[5]) ||
        argv[6][0] != '/') {
        return EXIT_USAGE;
    }
    for (int index = 6; index < argc; index++) {
        if (strcmp(argv[index], "--") == 0) {
            separator = index;
            break;
        }
    }
    if (separator < 10 || separator + 1 >= argc) {
        return EXIT_USAGE;
    }
    result = duplicate_checked_directory(argv[2], argv[3], &stage);
    if (result != 0) {
        return result;
    }
    work = (int)syscall(SYS_openat2, stage, argv[4], &directory_how, sizeof(directory_how));
    executable = (int)syscall(SYS_openat2, stage, argv[5], &executable_how,
                              sizeof(executable_how));
    if (work < 0 || executable < 0 || fstat(executable, &executable_status) != 0 ||
        !S_ISREG(executable_status.st_mode) || executable_status.st_uid != getuid() ||
        (executable_status.st_mode & 0100) == 0) {
        result = EXIT_DIRECTORY;
        goto done;
    }
    for (int index = 2; index < separator; index++) {
        if (index == 3 || index == 4 || index == 5 || index == 6) {
            continue;
        }
        result = set_close_on_exec(argv[index]);
        if (result != 0) {
            goto done;
        }
    }
    if (fchdir(work) != 0) {
        result = EXIT_SYSCALL;
        goto done;
    }
    hook_status = run_test_hook("before-probe-exec", argv[6], argv[5], argv[4], argv[5]);
    if (hook_status != 0) {
        result = EXIT_SYSCALL;
        goto done;
    }
    result = set_probe_environment();
    if (result != 0) {
        goto done;
    }
    child_argv = calloc((size_t)(argc - separator + 1), sizeof(*child_argv));
    if (child_argv == NULL) {
        result = EXIT_SYSCALL;
        goto done;
    }
    if (asprintf(&entrypoint_argv0, "/proc/self/cwd/../../%s", argv[5]) < 0) {
        result = EXIT_SYSCALL;
        goto done;
    }
    child_argv[0] = entrypoint_argv0;
    for (int index = separator + 1; index < argc; index++) {
        child_argv[index - separator] = argv[index];
    }
    syscall(SYS_execveat, executable, "", child_argv, environ, AT_EMPTY_PATH);
    result = EXIT_SYSCALL;
done:
    free(entrypoint_argv0);
    free(child_argv);
    if (executable >= 0) {
        close(executable);
    }
    if (work >= 0) {
        close(work);
    }
    if (stage >= 0) {
        close(stage);
    }
    return result;
}

static void usage(void) {
    fprintf(stderr,
            "usage: dotfiles-agent-atomic-publish directory-identity DIR\n"
            "       dotfiles-agent-atomic-publish directory-identity-fd FD\n"
            "       dotfiles-agent-atomic-publish identity DIR EXPECTED_DIR NAME\n"
            "       dotfiles-agent-atomic-publish identity-fd FD EXPECTED_DIR NAME\n"
            "       dotfiles-agent-atomic-publish move-noreplace SRC_DIR EXPECTED_SRC_DIR SRC_NAME DST_DIR EXPECTED_DST_DIR DST_NAME EXPECTED_SRC\n"
            "       dotfiles-agent-atomic-publish move-noreplace-fd SRC_FD EXPECTED_SRC_DIR SRC_NAME DST_FD EXPECTED_DST_DIR DST_NAME EXPECTED_SRC\n"
            "       dotfiles-agent-atomic-publish exchange SRC_DIR EXPECTED_SRC_DIR SRC_NAME DST_DIR EXPECTED_DST_DIR DST_NAME EXPECTED_SRC EXPECTED_DST\n"
            "       dotfiles-agent-atomic-publish exchange-fd SRC_FD EXPECTED_SRC_DIR SRC_NAME DST_FD EXPECTED_DST_DIR DST_NAME EXPECTED_SRC EXPECTED_DST\n"
            "       dotfiles-agent-atomic-publish unlink-if DIR EXPECTED_DIR NAME EXPECTED\n"
            "       dotfiles-agent-atomic-publish unlink-if-fd FD EXPECTED_DIR NAME EXPECTED\n"
            "       dotfiles-agent-atomic-publish symlink-noreplace-fd FD EXPECTED_DIR NAME TARGET\n"
            "       dotfiles-agent-atomic-publish remove-tree-fd PARENT_FD EXPECTED_PARENT NAME TREE_FD EXPECTED_TREE\n"
            "       dotfiles-agent-atomic-publish probe-exec STAGE_FD EXPECTED_STAGE WORK EXEC DISPLAY CLOSE_FD CLOSE_FD CLOSE_FD -- ARG...\n");
}

int main(int argc, char **argv) {
    if (argc == 3 && strcmp(argv[1], "directory-identity") == 0) {
        return command_directory_identity(argv[2]);
    }
    if (argc == 3 && strcmp(argv[1], "directory-identity-fd") == 0) {
        return command_directory_identity_fd(argv[2]);
    }
    if (argc == 5 && strcmp(argv[1], "identity") == 0) {
        return command_identity(argv[2], argv[3], argv[4]);
    }
    if (argc == 5 && strcmp(argv[1], "identity-fd") == 0) {
        return command_identity_fd(argv[2], argv[3], argv[4]);
    }
    if (argc == 9 && strcmp(argv[1], "move-noreplace") == 0) {
        return command_move_noreplace(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
                                      argv[8]);
    }
    if (argc == 9 && strcmp(argv[1], "move-noreplace-fd") == 0) {
        return command_move_noreplace_fd(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7],
                                         argv[8]);
    }
    if (argc == 10 && strcmp(argv[1], "exchange") == 0) {
        return command_exchange(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8],
                                argv[9]);
    }
    if (argc == 10 && strcmp(argv[1], "exchange-fd") == 0) {
        return command_exchange_fd(argv[2], argv[3], argv[4], argv[5], argv[6], argv[7], argv[8],
                                   argv[9]);
    }
    if (argc == 6 && strcmp(argv[1], "unlink-if") == 0) {
        return command_unlink_if(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc == 6 && strcmp(argv[1], "unlink-if-fd") == 0) {
        return command_unlink_if_fd(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc == 6 && strcmp(argv[1], "symlink-noreplace-fd") == 0) {
        return command_symlink_noreplace_fd(argv[2], argv[3], argv[4], argv[5]);
    }
    if (argc == 7 && strcmp(argv[1], "remove-tree-fd") == 0) {
        return command_remove_tree_fd(argv[2], argv[3], argv[4], argv[5], argv[6]);
    }
    if (argc >= 11 && strcmp(argv[1], "probe-exec") == 0) {
        return command_probe_exec(argc, argv);
    }
    usage();
    return EXIT_USAGE;
}
