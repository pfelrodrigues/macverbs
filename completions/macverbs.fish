function __macverbs_should_offer_completions_for_flags_or_options -a expected_commands
    set -l non_repeating_flags_or_options $argv[2..]
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __macverbs_parse_tokens
    test "$commands" = "$expected_commands"; and return $non_repeating_flags_or_options_absent
end

function __macverbs_should_offer_completions_for_positional -a expected_commands positional_index_comparison expected_positional_index
    set -l non_repeating_flags_or_options
    set -l non_repeating_flags_or_options_absent 0
    set -l positional_index 0
    set -l commands
    __macverbs_parse_tokens
    test "$commands" = "$expected_commands" -a \( "$positional_index" "$positional_index_comparison" "$expected_positional_index" \)
end

function __macverbs_parse_tokens -S
    set -l unparsed_tokens (__macverbs_tokens -pc)
    switch $unparsed_tokens[1]
    case 'macverbs'
        __macverbs_parse_subcommand 0 'json' 'version' 'h/help'
        switch $unparsed_tokens[1]
        case 'calendar'
            __macverbs_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __macverbs_parse_subcommand 0 'days=' 'version' 'h/help'
            case 'add'
                __macverbs_parse_subcommand 1 'start=' 'end=' 'calendar=' 'version' 'h/help'
            case 'calendars'
                __macverbs_parse_subcommand 0 'version' 'h/help'
            end
        case 'config'
            __macverbs_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'path'
                __macverbs_parse_subcommand 0 'version' 'h/help'
            case 'calendars'
                __macverbs_parse_subcommand 0 'version' 'h/help'
                switch $unparsed_tokens[1]
                case 'show'
                    __macverbs_parse_subcommand 0 'version' 'h/help'
                case 'init'
                    __macverbs_parse_subcommand 0 'force' 'version' 'h/help'
                end
            end
        case 'doctor'
            __macverbs_parse_subcommand 0 'version' 'h/help'
        case 'mail'
            __macverbs_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'accounts'
                __macverbs_parse_subcommand 0 'version' 'h/help'
            case 'unread'
                __macverbs_parse_subcommand 0 'version' 'h/help'
            case 'list'
                __macverbs_parse_subcommand 0 'account=' 'limit=' 'mailbox=' 'version' 'h/help'
            case 'read'
                __macverbs_parse_subcommand 1 'account=' 'version' 'h/help'
            case 'archive'
                __macverbs_parse_subcommand -r 1 'account=' 'version' 'h/help'
            case 'delete'
                __macverbs_parse_subcommand -r 1 'account=' 'version' 'h/help'
            case 'attachments'
                __macverbs_parse_subcommand 1 'dest=' 'account=' 'version' 'h/help'
            case 'draft'
                __macverbs_parse_subcommand 1 'body-file=' 'account=' 'attach=+' 'version' 'h/help'
            case 'compose'
                __macverbs_parse_subcommand 0 'subject=' 'body-file=' 'to=+' 'cc=+' 'account=' 'version' 'h/help'
            end
        case 'notes'
            __macverbs_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'list'
                __macverbs_parse_subcommand 0 'folder=' 'version' 'h/help'
            case 'read'
                __macverbs_parse_subcommand 1 'version' 'h/help'
            case 'create'
                __macverbs_parse_subcommand 2 'folder=' 'version' 'h/help'
            case 'search'
                __macverbs_parse_subcommand 1 'version' 'h/help'
            end
        case 'reminders'
            __macverbs_parse_subcommand 0 'version' 'h/help'
            switch $unparsed_tokens[1]
            case 'lists'
                __macverbs_parse_subcommand 0 'version' 'h/help'
            case 'list'
                __macverbs_parse_subcommand 0 'list=' 'version' 'h/help'
            case 'add'
                __macverbs_parse_subcommand 1 'list=' 'due=' 'notes=' 'priority=' 'version' 'h/help'
            case 'done'
                __macverbs_parse_subcommand 1 'list=' 'version' 'h/help'
            case 'move'
                __macverbs_parse_subcommand 1 'from=' 'to=' 'version' 'h/help'
            case 'edit'
                __macverbs_parse_subcommand 1 'list=' 'due=' 'priority=' 'notes=' 'version' 'h/help'
            case 'mklist'
                __macverbs_parse_subcommand 1 'version' 'h/help'
            case 'delete'
                __macverbs_parse_subcommand 1 'list=' 'version' 'h/help'
            end
        case 'help'
            __macverbs_parse_subcommand -r 1 'version'
        end
    end
end

function __macverbs_tokens
    if test (string split -m 1 -f 1 -- . "$FISH_VERSION") -gt 3
        commandline --tokens-raw $argv
    else
        commandline -o $argv
    end
end

function __macverbs_parse_subcommand -S -a positional_count
    argparse -s r -- $argv
    set -l option_specs $argv[2..]
    set -l is_repeating_positional $_flag_r
    set -el _flag_r
    set -a commands $unparsed_tokens[1]
    set positional_index 0
    while true
        set -e unparsed_tokens[1]
        argparse -sn "$commands" $option_specs -- $unparsed_tokens 2> /dev/null
        set unparsed_tokens $argv
        set positional_index (math $positional_index + 1)
        for non_repeating_flag_or_option in $non_repeating_flags_or_options
            if set -ql "_flag_$(string replace -a - _ -- $non_repeating_flag_or_option)"
                set non_repeating_flags_or_options_absent 1
                break
            end
        end
        test (count $unparsed_tokens) -eq 0 -o \( -z "$is_repeating_positional" -a "$positional_index" -gt "$positional_count" \) && break
    end
end

function __macverbs_complete_directories
    set -l token (commandline -t)
    string match -- '*/' $token
    set -l subdirs $token*/
    printf %s\n $subdirs
end

function __macverbs_custom_completion
    set -x SAP_SHELL fish
    set -x SAP_SHELL_VERSION $FISH_VERSION
    set -l tokens (__macverbs_tokens -p)
    if test -z "$(__macverbs_tokens -t)"
        set -l index (count (__macverbs_tokens -pc))
        set tokens $tokens[..$index] \'\' $tokens[(math $index + 1)..]
    end
    command $tokens[1] $argv $tokens
end

complete -c 'macverbs' -f
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs" json' -l 'json' -d 'Emit one JSON value on stdout (place before the subcommand).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'calendar' -d 'Calendar events (EventKit).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'config' -d 'Show and initialize macverbs config (calendars.json).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'doctor' -d 'Report environment readiness (no permission prompts).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'mail' -d 'Mail accounts and messages (Apple Events).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'notes' -d 'Notes folders and notes (Apple Events).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'reminders' -d 'Reminders via EventKit.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs" -eq 1' -fa 'help' -d 'Show subcommand help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs calendar" -eq 1' -fa 'list' -d 'List upcoming events (recurring expanded; labels from config).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs calendar" -eq 1' -fa 'add' -d 'Create a timed calendar event (EventKit).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs calendar" -eq 1' -fa 'calendars' -d 'List event calendars with UID (for calendars.json).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar list" days' -l 'days' -d 'Days ahead of today to include (default: 7; 0 = today only).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar list" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar add" start' -l 'start' -d 'Start datetime (YYYY-MM-DD HH:MM).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar add" end' -l 'end' -d 'End datetime (YYYY-MM-DD HH:MM).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar add" calendar' -l 'calendar' -d 'Calendar alias, title, or UID. Empty = default calendar.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar add" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar calendars" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs calendar calendars" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs config" -eq 1' -fa 'path' -d 'Print the resolved config directory and calendars.json path.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs config" -eq 1' -fa 'calendars' -d 'Manage calendars.json (UID → label map).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config path" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config path" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs config calendars" -eq 1' -fa 'show' -d 'Show the current calendars.json alias map.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs config calendars" -eq 1' -fa 'init' -d 'Create calendars.json from EventKit calendars (edit labels afterward).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars show" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars show" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars init" force' -l 'force' -d 'Overwrite an existing calendars.json.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars init" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs config calendars init" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs doctor" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs doctor" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'accounts' -d 'List configured Mail accounts.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'unread' -d 'Unread message counts per account.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'list' -d 'List recent messages (all accounts by default).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'read' -d 'Read a message by message-id (searches inbox and archive).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'archive' -d 'Archive messages (move to archive; effect verified).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'delete' -d 'Delete messages (move to trash; effect verified).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'attachments' -d 'Save attachments from a message (searches inbox and archive).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'draft' -d 'Create a reply draft to a message (never sends).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs mail" -eq 1' -fa 'compose' -d 'Create a new email draft (never sends).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail accounts" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail accounts" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail unread" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail unread" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail list" account' -l 'account' -d 'Filter by account name (empty = all accounts).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail list" limit' -l 'limit' -d 'Max messages per account (default: 20).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail list" mailbox' -l 'mailbox' -d 'Mailbox to list: inbox or archive (default: inbox).' -rfka 'inbox archive'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail list" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail read" account' -l 'account' -d 'Filter by account name (empty = all accounts).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail read" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail read" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail archive" account' -l 'account' -d 'Account that owns the messages (required).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail archive" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail archive" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail delete" account' -l 'account' -d 'Account that owns the messages (required).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail delete" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail delete" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail attachments" dest' -l 'dest' -d 'Destination directory for saved files (required).' -rfa '(__macverbs_complete_directories)'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail attachments" account' -l 'account' -d 'Filter by account name (empty = all accounts).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail attachments" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail attachments" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail draft" body-file' -l 'body-file' -d 'File with the draft body (required).' -rF
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail draft" account' -l 'account' -d 'Filter by account name (empty = all accounts).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail draft"' -l 'attach' -d 'File path to attach (repeatable).' -rF
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail draft" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail draft" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose" subject' -l 'subject' -d 'Subject line (required).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose" body-file' -l 'body-file' -d 'File with the draft body (required).' -rF
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose"' -l 'to' -d 'To recipient (repeatable; empty = fill later in Mail).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose"' -l 'cc' -d 'Cc recipient (repeatable).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose" account' -l 'account' -d 'Sender account name (empty = Mail default).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs mail compose" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs notes" -eq 1' -fa 'list' -d 'List notes in a folder (default: Notes).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs notes" -eq 1' -fa 'read' -d 'Read a note by exact title (first match).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs notes" -eq 1' -fa 'create' -d 'Create a note in a folder (default: Notes).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs notes" -eq 1' -fa 'search' -d 'Search notes by title or body contains query.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes list" folder' -l 'folder' -d 'Notes folder name (default: Notes).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes list" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes read" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes read" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes create" folder' -l 'folder' -d 'Notes folder name (default: Notes).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes create" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes create" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes search" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs notes search" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'lists' -d 'List reminder lists and pending counts.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'list' -d 'List incomplete reminders (optionally filter by list).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'add' -d 'Create a reminder.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'done' -d 'Mark a reminder complete (exact title match).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'move' -d 'Move a reminder between lists (exact title match).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'edit' -d 'Edit due date, priority, and/or notes (exact title match).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'mklist' -d 'Ensure a reminder list exists (create if missing).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_positional "macverbs reminders" -eq 1' -fa 'delete' -d 'Delete a reminder without completing it (exact title match).'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders lists" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders lists" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders list" list' -l 'list' -d 'Reminder list name. Empty = all lists.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders list" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders list" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" list' -l 'list' -d 'List name. Empty = default list.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" due' -l 'due' -d 'Due date: YYYY-MM-DD or YYYY-MM-DD HH:MM.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" notes' -l 'notes' -d 'Notes / body.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" priority' -l 'priority' -d 'Priority: high, medium, or low.' -rfka 'high medium low'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders add" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders done" list' -l 'list' -d 'List name. Empty = default list.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders done" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders done" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders move" from' -l 'from' -d 'Source list name (required).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders move" to' -l 'to' -d 'Destination list name (required).' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders move" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders move" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" list' -l 'list' -d 'List name. Empty = default list.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" due' -l 'due' -d 'Due date: YYYY-MM-DD or YYYY-MM-DD HH:MM.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" priority' -l 'priority' -d 'Priority: high, medium, low, or none (clear).' -rfka 'high medium low none'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" notes' -l 'notes' -d 'Notes / body.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders edit" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders mklist" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders mklist" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders delete" list' -l 'list' -d 'List name. Empty = default list.' -rfka ''
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders delete" version' -l 'version' -d 'Show the version.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs reminders delete" h help' -s 'h' -l 'help' -d 'Show help information.'
complete -c 'macverbs' -n '__macverbs_should_offer_completions_for_flags_or_options "macverbs help" version' -l 'version' -d 'Show the version.'
