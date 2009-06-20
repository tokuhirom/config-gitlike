package Config::GitLike;

use strict;
use warnings;
use File::Spec;
use Cwd;
use File::HomeDir;
use Regexp::Common;
use Any::Moose;
use Scalar::Util qw(openhandle);
use Fcntl qw(:DEFAULT :flock);
use 5.008;


has 'confname' => (
    is => 'rw',
    required => 1,
    isa => 'Str',
);

# not defaulting to {} allows the predicate is_loaded
# to determine whether data has been loaded yet or not
has 'data' => (
    is => 'rw',
    predicate => 'is_loaded',
    isa => 'HashRef',
);

# key => bool
has 'multiple' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { +{} },
);

# filename where the definition of each key was loaded from
has 'origins' => (
    is => 'rw',
    isa => 'HashRef',
    default => sub { +{} },
);

has 'config_files' => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub { [] },
);

# default to being more relaxed than git, but allow enforcement
# of only-write-things-that-git-config-can-read if you want to
has 'compatible' => (
    is => 'rw',
    isa => 'Bool',
    default => sub { 0 },
);

sub set_multiple {
    my $self = shift;
    my ($name, $mult) = @_, 1;
    $self->multiple->{$name} = $mult;
}

sub is_multiple {
    my $self = shift;
    my $name = shift;
    return if !defined $name;
    return $self->multiple->{$name};
}

sub load {
    my $self = shift;
    my $path = shift || Cwd::cwd;
    $self->data({});
    $self->multiple({});
    $self->config_files([]);
    $self->load_global;
    $self->load_user;
    $self->load_dirs( $path );
    return wantarray ? %{$self->data} : \%{$self->data};
}

sub dir_file {
    my $self = shift;
    return "." . $self->confname;
}

sub load_dirs {
    my $self = shift;
    my $path = shift;
    my($vol, $dirs, undef) = File::Spec->splitpath( $path, 1 );
    my @dirs = File::Spec->splitdir( $dirs );
    while (@dirs) {
        my $path = File::Spec->catpath(
            $vol, File::Spec->catdir(@dirs), $self->dir_file
        );
        if (-f $path) {
            $self->load_file( $path );
            last;
        }
        pop @dirs;
    }
}

sub global_file {
    my $self = shift;
    return "/etc/" . $self->confname;
}

sub load_global {
    my $self = shift;
    return unless -f $self->global_file;
    return $self->load_file( $self->global_file );
}

sub user_file {
    my $self = shift;
    return
        File::Spec->catfile( File::HomeDir->my_home, "." . $self->confname );
}

sub load_user {
    my $self = shift;
    return unless -f $self->user_file;
    return $self->load_file( $self->user_file );
}

# returns undef if the file was unable to be opened
sub _read_config {
    my $filename = shift;
    my $lock_and_return_fh = shift;

    my $fh;
    if ( !open($fh, '<', $filename) && $lock_and_return_fh ) {
        open($fh, '>', $filename);
        flock($fh, LOCK_EX);
        return ('', $fh);
    }

    # lock the filehandle because we want to write to it later and want to
    # (try to) ensure that no one else writes to the file in the meantime so
    # that we don't overwrite their update
    flock($fh, LOCK_EX) if $lock_and_return_fh;

    my $c = do {local $/; <$fh>};

    close $fh unless $lock_and_return_fh;

    $c =~ s/\n*$/\n/; # Ensure it ends with a newline

    return openhandle $fh ? ($c, $fh) : $c;
}

sub load_file {
    my $self = shift;
    my ($filename) = @_;
    my $c = _read_config($filename);

    $self->parse_content(
        content  => $c,
        callback => sub {
            $self->define(@_, origin => $filename);
        },
        error    => sub {
            die "Error parsing $filename, near:\n@_\n";
        },
    );

    # note this filename as having been loaded
    push @{$self->config_files}, $filename;

    return $self->data;
}

sub parse_content {
    my $self = shift;
    my %args = (
        content  => '',
        callback => sub {},
        error    => sub {},
        @_,
    );
    my $c = $args{content};
    return if !$c;          # nothing to do if content is empty
    my $length = length $c;

    my $section_regex
        = $self->compatible ? qr/\A\[([0-9a-z.-]+)(?:[\t ]*"([^\n]*?)")?\]/im
                            : qr/\A\[([^\s\[\]"]+)(?:[\t ]*"([^\n]*?)")?\]/im;

    my $key_regex
        = $self->compatible ? qr/\A([a-z][0-9a-z-]*)[\t ]*([#;].*)?$/im
                            : qr/\A([^=\n]+?)[\t ]*([#;].*)?$/im;

    my $key_value_regex
        = $self->compatible ? qr/\A([a-z][0-9a-z-]*)[\t ]*=[\t ]*/im
                            : qr/\A([^=\n]+?)[\t ]*=[\t ]*/im;

    my($section, $prev) = (undef, '');
    while (1) {
        # drop leading white space and blank lines
        $c =~ s/\A\s*//im;

        my $offset = $length - length($c);
        # drop to end of line on comments
        if ($c =~ s/\A[#;].*?$//im) {
            next;
        }
        # [sub]section headers of the format [section "subsection"] (with
        # unlimited whitespace between) or [section.subsection] variable
        # definitions may directly follow the section header, on the same line!
        # - rules for sections: not case sensitive, only alphanumeric
        #   characters, -, and . allowed
        # - rules for subsections enclosed in ""s: case sensitive, can
        #   contain any character except newline, " and \ must be escaped
        # - rules for subsections with section.subsection alternate syntax:
        #   same rules as for sections
        elsif ($c =~ s/$section_regex//) {
            $section = lc $1;
            return $args{error}->(
                content => $args{content},
                offset =>  $offset,
                # don't allow quoted subsections to contain unquoted
                # double-quotes or backslashes
            ) if $2 && $2 =~ /(?<!\\)(?:"|\\)/;
            $section .= ".$2" if defined $2;
            $args{callback}->(
                section    => $section,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        }
        # keys followed by a unlimited whitespace and (optionally) a comment
        # (no value)
        #
        # for keys, we allow any characters that won't screw up the parsing
        # (= and newline) in non-compatible mode, and match non-greedily to
        # allow any trailing whitespace to be dropped
        #
        # in compatible mode, keys can contain only 0-9a-z-
        elsif ($c =~ s/$key_regex//) {
            $args{callback}->(
                section    => $section,
                name       => lc $1,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        }
        # key/value pairs (this particular regex matches only the key part and
        # the =, with unlimited whitespace around the =)
        elsif ($c =~ s/$key_value_regex//) {
            my $name = lc $1;
            my $value = "";
            # parse the value
            while (1) {
                # comment or no content left on line
                if ($c =~ s/\A([ \t]*[#;].*?)?$//im) {
                    last;
                }
                # any amount of whitespace between words becomes a single space
                elsif ($c =~ s/\A[\t ]+//im) {
                    $value .= ' ';
                }
                # line continuation (\ character followed by new line)
                elsif ($c =~ s/\A\\\r?\n//im) {
                    next;
                }
                # escaped quote characters are part of the value
                elsif ($c =~ s/\A\\(['"])//im) {
                    $value .= $1;
                }
                # escaped newline in config is translated to actual newline
                elsif ($c =~ s/\A\\n//im) {
                    $value .= "\n";
                }
                # escaped tab in config is translated to actual tab
                elsif ($c =~ s/\A\\t//im) {
                    $value .= "\t";
                }
                # escaped backspace in config is translated to actual backspace
                elsif ($c =~ s/\A\\b//im) {
                    $value .= "\b";
                }
                # quote-delimited value (possibly containing escape codes)
                elsif ($c =~ s/\A"([^"\\]*(?:(?:\\\n|\\[tbn"\\])[^"\\]*)*)"//im) {
                    my $v = $1;
                    # remove all continuations (\ followed by a newline)
                    $v =~ s/\\\n//g;
                    # swap escaped newlines with actual newlines
                    $v =~ s/\\n/\n/g;
                    # swap escaped tabs with actual tabs
                    $v =~ s/\\t/\t/g;
                    # swap escaped backspaces with actual backspaces
                    $v =~ s/\\b/\b/g;
                    # swap escaped \ with actual \
                    $v =~ s/\\\\/\\/g;
                    $value .= $v;
                }
                # valid value (no escape codes)
                elsif ($c =~ s/\A([^\t \\\n]+)//im) {
                    $value .= $1;
                # unparseable
                }
                else {
                    # Note that $args{content} is the _original_
                    # content, not the nibbled $c, which is the
                    # remaining unparsed content
                    return $args{error}->(
                        content => $args{content},
                        offset =>  $offset,
                    );
                }
            }
            $args{callback}->(
                section    => $section,
                name       => $name,
                value      => $value,
                offset     => $offset,
                length     => ($length - length($c)) - $offset,
            );
        }
        # end of content string; all done now
        elsif (not length $c) {
            last;
        }
        # unparseable
        else {
            # Note that $args{content} is the _original_ content, not
            # the nibbled $c, which is the remaining unparsed content
            return $args{error}->(
                content => $args{content},
                offset  => $offset,
            );
        }
    }
}

sub define {
    my $self = shift;
    my %args = (
        section => undef,
        name    => undef,
        value   => undef,
        origin  => undef,
        @_,
    );
    return unless defined $args{name};
    $args{name} = lc $args{name};
    my $key = join(".", grep {defined} @args{qw/section name/});

    # we're either adding a whole new key or adding a multiple key from
    # the same file
    if ( !defined $self->origins->{$key}
        || $self->origins->{$key} eq $args{origin} ) {
        if ($self->is_multiple($key)) {
            push @{$self->data->{$key} ||= []}, $args{value};
        }
        elsif (exists $self->data->{$key}) {
            $self->set_multiple($key);
            $self->data->{$key} = [$self->data->{$key}, $args{value}];
        }
        else {
            $self->data->{$key} = $args{value};
        }
    }
    # we're overriding a key set previously from a different file
    else {
        # un-mark as multiple if it was previously marked as such
        $self->set_multiple( $key, 0 ) if $self->is_multiple( $key );

        # set the new value
        $self->data->{$key} = $args{value};
    }
    $self->origins->{$key} = $args{origin};
}

sub cast {
    my $self = shift;
    my %args = (
        value => undef,
        as    => undef, # bool, int, or num
        human => undef, # true value / false value
        @_,
    );

    use constant {
        BOOL_TRUE_REGEX => qr/^(?:true|yes|on|-?0*1)$/i,
        BOOL_FALSE_REGEX => qr/^(?:false|no|off|0*)$/i,
        NUM_REGEX => qr/^-?[0-9]*\.?[0-9]*[kmg]?$/,
    };

    if (defined $args{as} && $args{as} eq 'bool-or-int') {
        if ( $args{value} =~ NUM_REGEX ) {
            $args{as} = 'int';
        }
        elsif ( $args{value} =~ BOOL_TRUE_REGEX ||
            $args{value} =~ BOOL_FALSE_REGEX ) {
            $args{as} = 'bool';
        }
        elsif ( !defined $args{value} ) {
            $args{as} = 'bool';
        }
        else {
            die "Invalid bool-or-int '$args{value}'\n";
        }
    }

    my $v = $args{value};
    return $v unless defined $args{as};
    if ($args{as} =~ /bool/i) {
        return 1 unless defined $v;
        if ( $v =~  BOOL_TRUE_REGEX ) {
            if ( $args{human} ) {
                return 'true';
            }
            else {
                return 1;
            }
        }
        elsif ($v =~ BOOL_FALSE_REGEX ) {
            if ( $args{human} ) {
                return 'false';
            }
            else {
                return 0;
            }
        }
        else {
            die "Invalid bool '$args{value}'\n";
        }
    }
    elsif ($args{as} =~ /int|num/) {
        die "Invalid unit while casting to $args{as}\n"
            unless $v =~ NUM_REGEX;

        if ($v =~ s/([kmg])$//) {
            $v *= 1024 if $1 eq "k";
            $v *= 1024*1024 if $1 eq "m";
            $v *= 1024*1024*1024 if $1 eq "g";
        }

        return $args{as} eq 'int' ? int $v : $v + 0;
    }
}

sub get {
    my $self = shift;
    my %args = (
        key => undef,
        as  => undef,
        human  => undef,
        filter => '',
        @_,
    );
    $self->load unless $self->is_loaded;

    my ($section, $subsection, $name) = _split_key($args{key});
    $args{key} = join( '.',
        grep { defined } (lc $section, $subsection, lc $name),
    );

    return undef unless exists $self->data->{$args{key}};
    my $v = $self->data->{$args{key}};
    if (ref $v) {
        my @results;
        if (defined $args{filter}) {
            if ($args{filter} =~ s/^!//) {
                @results = grep { !/$args{filter}/i } @{$v};
            }
            else {
                @results = grep { m/$args{filter}/i } @{$v};
            }
        }
        die "Multiple values" unless @results <= 1;
        $v = $results[0];
    }
    return $self->cast( value => $v, as => $args{as},
        human => $args{human} );
}

# I'm pretty sure that someone can come up with an edge case where stripping
# all balanced quotes like this is not the right thing to do, but I don't
# see it actually being a problem in practice.
sub _remove_balanced_quotes {
    my $key = shift;

    no warnings 'uninitialized';
    $key = join '', map { s/"(.*)"/$1/; $_ } split /("[^"]+"|[^.]+)/, $key;
    $key = join '', map { s/'(.*)'/$1/; $_ } split /('[^']+'|[^.]+)/, $key;

    return $key;
}

sub get_all {
    my $self = shift;
    my %args = (
        key => undef,
        as  => undef,
        @_,
    );
    $self->load unless $self->is_loaded;
    my ($section, $subsection, $name) = _split_key($args{key});
    $args{key} = join('.',
        grep { defined } (lc $section, $subsection, lc $name),
    );

    return undef unless exists $self->data->{$args{key}};
    my $v = $self->data->{$args{key}};
    my @v = ref $v ? @{$v} : ($v);

    if (defined $args{filter}) {
        if ($args{filter} =~ s/^!//) {
            @v = grep { !/$args{filter}/i } @v;
        }
        else {
            @v = grep { m/$args{filter}/i } @v;
        }
    }

    @v = map {$self->cast( value => $_, as => $args{as} )} @v;
    return wantarray ? @v : \@v;
}

sub get_regexp {
    my $self = shift;

    my %args = (
        key => undef,
        filter => undef,
        as  => undef,
        @_,
    );

    $self->load unless $self->is_loaded;

    $args{key} = lc $args{key};

    my %results;
    for my $key (keys %{$self->data}) {
        $results{$key} = $self->data->{$key} if lc $key =~ m/$args{key}/i;
    }

    if (defined $args{filter}) {
        if ($args{filter} =~ s/^!//) {
            map { delete $results{$_} if $results{$_} =~ m/$args{filter}/i }
                keys %results;
        }
        else {
            map { delete $results{$_} if $results{$_} !~ m/$args{filter}/i }
                keys %results;
        }
    }

    @results{keys %results} =
        map { $self->cast(
                value => $results{$_},
                as => $args{as}
            ); } keys %results;
    return wantarray ? %results : \%results;
}

sub dump {
    my $self = shift;

    return %{$self->data} if wantarray;

    my $data = '';
    for my $key (sort keys %{$self->data}) {
        my $str;
        if (defined $self->data->{$key}) {
            $str = "$key=";
            if ( $self->is_multiple($key) ) {
                $str .= '[';
                $str .= join(', ', @{$self->data->{$key}});
                $str .= "]\n";
            }
            else {
                $str .= $self->data->{$key}."\n";
            }
        }
        else {
            $str = "$key\n";
        }
        if (!defined wantarray) {
            print $str;
        }
        else {
            $data .= $str;
        }
    }

    return $data if defined wantarray;
}

sub format_section {
    my $self = shift;

    my %args = (
        section => undef,
        bare    => undef,
        @_,
    );

    if ($args{section} =~ /^(.*?)\.(.*)$/) {
        my ($section, $subsection) = ($1, $2);
        $subsection =~ s/(["\\])/\\$1/g;
        my $ret = qq|[$section "$subsection"]|;
        $ret .= "\n" unless $args{bare};
        return $ret;
    }
    else {
        my $ret = qq|[$args{section}]|;
        $ret .= "\n" unless $args{bare};
        return $ret;
    }
}

sub format_definition {
    my $self = shift;
    my %args = (
        key   => undef,
        value => undef,
        bare  => undef,
        @_,
    );
    my $quote = $args{value} =~ /(^\s|;|#|\s$)/ ? '"' : '';
    $args{value} =~ s/\\/\\\\/g;
    $args{value} =~ s/"/\\"/g;
    $args{value} =~ s/\t/\\t/g;
    $args{value} =~ s/\n/\\n/g;
    my $ret = "$args{key} = $quote$args{value}$quote";
    $ret = "\t$ret\n" unless $args{bare};
    return $ret;
}

# Given a key, return its variable name, section, and subsection
# parts. Doesn't do any lowercase transformation.
sub _split_key {
    my $key = shift;

    my ($name, $section, $subsection);
    # allow quoting of the key to, for example, preserve
    # . characters in the key
    if ( $key =~ s/\.["'](.*)["']$// ) {
        $name = $1;
        $section = $key;
    }
    else {
        $key =~ /^(?:(.*)\.)?(.*)$/;
        # If we wanted, we could interpret quoting of the section name to
        # allow for setting keys with section names including . characters.
        # But git-config doesn't do that, so we won't bother for now. (Right
        # now it will read these section names correctly but won't set them.)
        ($section, $name) = map { _remove_balanced_quotes($_) }
            grep { defined $_ } ($1, $2);
    }

    # Make sure the section name we're comparing against has
    # case-insensitive section names and case-sensitive subsection names.
    if (defined $section) {
        $section =~ m/^([^.]+)(?:\.(.*))?$/;
        ($section, $subsection) = ($1, $2);
    }
    else {
        ($section, $subsection) = (undef) x 2;
    }
    return ($section, $subsection, $name);
}

sub group_set {
    my $self = shift;
    my ($filename, $args_ref) = @_;

    my ($c, $fh) = _read_config($filename, 1);  # undef if file doesn't exist

    # loop through each value to set, modifying the content to be written
    # or erroring out as we go
    for my $args_hash (@{$args_ref}) {
        my %args = %{$args_hash};

        my ($section, $subsection, $name) = _split_key($args{key});
        my $key = join( '.',
            grep { defined } (lc $section, $subsection, lc $name),
        );

        $args{multiple} = $self->is_multiple($key)
            unless defined $args{multiple};

        die "No section given in key or invalid key $args{key}\n"
            unless defined $section;

        die "Invalid variable name $name\n"
            if $self->_invalid_variable_name($name);

        die "Invalid section name $section\n"
            if $self->_invalid_section_name($section);

        die "Unescaped backslash or \" in subsection $subsection\n"
            if defined $subsection && $subsection =~ /(?<!\\)(?:"|\\)/;

        $args{value} = $self->cast(
            value => $args{value},
            as    => $args{as},
            human => 1,
        ) if defined $args{value} && defined $args{as};

        my $new;
        my @replace;

        # use this for comparison
        my $cmp_section
            = defined $subsection ? join('.', lc $section, $subsection)
                                  : lc $section;
        # ...but this for writing (don't lowercase)
        my $combined_section
            = defined $subsection ? join('.', $section, $subsection)
                                  : $section;

        # There's not really a good, simple way to get around parsing the
        # content for each of the values we're setting. If we wanted to
        # extract the offsets for every single one using only a single parse
        # run, we'd end up having to munge all the offsets afterwards as we
        # did the actual replacement since every time we did a replacement it
        # would change the offsets for anything that was formerly to be added
        # at a later offset. Which I'm not sure is any better than just
        # parsing it again.
        $self->parse_content(
            content  => $c,
            callback => sub {
                my %got = @_;
                return unless $got{section} eq $cmp_section;
                $new = $got{offset} + $got{length};
                return unless defined $got{name};

                my $matched = 0;
                # variable names are case-insensitive
                if (lc $name eq $got{name}) {
                    if (defined $args{filter}) {
                        # copy the filter arg here since this callback may
                        # be called multiple times and we don't want to
                        # modify the original value
                        my $filter = $args{filter};
                        if ($filter =~ s/^!//) {
                            $matched = 1 if ($got{value} !~ m/$filter/i);
                        }
                        elsif ($got{value} =~ m/$filter/i) {
                            $matched = 1;
                        }
                    }
                    else {
                        $matched = 1;
                    }
                }

                push @replace, {offset => $got{offset}, length => $got{length}}
                    if $matched;
            },
            error    => sub {
                die "Error parsing $filename, near:\n@_\n";
            },
        );

        die "Multiple occurrences of non-multiple key?"
            if @replace > 1 && !$args{multiple};

        if (defined $args{value}) {
            if (@replace
                    && (!$args{multiple} || $args{replace_all})) {
                # Replacing existing value(s)

                # if the string we're replacing with is not the same length as
                # what's being replaced, any offsets following will be wrong.
                # save the difference between the lengths here and add it to
                # any offsets that follow.
                my $difference = 0;

                # when replacing multiple values, we combine them all into one,
                # which is kept at the position of the last one
                my $last = pop @replace;

                # kill all values that are not last
                ($c, $difference) = _unset_variables(\@replace, $c,
                    $difference);

                # substitute the last occurrence with the new value
                substr(
                    $c,
                    $last->{offset}-$difference,
                    $last->{length},
                    $self->format_definition(
                        key   => $name,
                        value => $args{value},
                        bare  => 1,
                        ),
                    );
            }
            elsif (defined $new) {
                # Adding a new value to the end of an existing block
                substr(
                    $c,
                    index($c, "\n", $new)+1,
                    0,
                    $self->format_definition(
                        key   => $name,
                        value => $args{value}
                    )
                );
            }
            else {
                # Adding a new section
                $c .= $self->format_section( section => $combined_section );
                $c .= $self->format_definition(
                    key => $name,
                    value => $args{value},
                );
            }
        }
        else {
            # Removing an existing value (unset / unset-all)
            die "No occurrence of $args{key} found to unset in $filename\n"
                unless @replace;

            ($c, undef) = _unset_variables(\@replace, $c, 0);
        }
    }
    return _write_config( $filename, $c );
    # release lock
    close $fh;
}

sub set {
    my $self = shift;
    my (%args) = (
        key      => undef,
        value    => undef,
        filename => undef,
        filter   => undef,
        as       => undef,
        multiple => undef,
        @_
    );

    my $filename = $args{filename};
    delete $args{filename};

    return $self->group_set( $filename, [ \%args ] );
}

sub _unset_variables {
    my ($variables, $c, $difference) = @_;

    for my $var (@{$variables}) {
        # start from either the last newline or the last section
        # close bracket, since variable definitions can occur
        # immediately following a section header without a \n
        my $newline = rindex($c, "\n", $var->{offset}-$difference);
        # need to add 1 here to not kill the ] too
        my $bracket = rindex($c, ']', $var->{offset}-$difference) + 1;
        my $start = $newline > $bracket ? $newline : $bracket;

        my $length =
            index($c, "\n", $var->{offset}-$difference+$var->{length})-$start;

        substr(
            $c,
            $start,
            $length,
            '',
        );
        $difference += $length;
    }

    return ($c, $difference);
}

# In non-git-compatible mode, variables names can contain any characters that
# aren't newlines or = characters, but cannot start or end with whitespace.
#
# Allowing . characters in variable names actually makes it so you
# can get collisions between identifiers for things that are not
# actually the same.
#
# For example, you could have a collision like this:
# [section "foo"] bar.com = 1
# [section] foo.bar.com = 1
#
# Both of these would be turned into 'section.foo.bar.com'. But it's
# unlikely to ever actually come up, since you'd have to have
# a *need* to have two things like this that are very similar
# and yet different.
sub _invalid_variable_name {
    my ($self, $name) = @_;

    if ($self->compatible) {
        return $name !~ /^[a-z][0-9a-z-]*$/i;
    }
    else {
        return $name !~ /^[^=\n]*$/ || $name =~ /(?:^[ \t]+|[ \t+]$)/;
    }
}

# section, NOT subsection!
sub _invalid_section_name {
    my ($self, $section) = @_;

    if ($self->compatible) {
        return $section !~ /^[0-9a-z-.]+$/i;
    }
    else {
        return $section =~ /\s|\[|\]|"/;
    }
}

# write config with locking
sub _write_config {
    my($filename, $content) = @_;

    # allow nested symlinks but only within reason
    my $max_depth = 5;

    # resolve symlinks
    while ($max_depth--) {
        my $readlink = readlink $filename;
        $filename = $readlink if defined $readlink;
    }

    # write new config file to temp file
    sysopen(my $fh, "${filename}.lock", O_CREAT|O_EXCL|O_WRONLY)
        or die "Can't open ${filename}.lock for writing: $!\n";
    print $fh $content;
    close $fh;

    # atomic rename
    rename("${filename}.lock", ${filename})
        or die "Can't rename ${filename}.lock to ${filename}: $!\n";
}

sub rename_section {
    my $self = shift;

    my (%args) = (
        from        => undef,
        to          => undef,
        filename    => undef,
        @_
    );

    die "No section to rename from given\n" unless defined $args{from};

    my ($c, $fh) = _read_config($args{filename}, 1);
    # file couldn't be opened = nothing to rename
    return if !defined($c);

    ($args{from}, $args{to}) = map { _remove_balanced_quotes($_) }
                                grep { defined $_ } ($args{from}, $args{to});

    my @replace;
    my $prev_matched = 0;
    $self->parse_content(
        content  => $c,
        callback => sub {
            my %got = @_;

            $replace[-1]->{section_is_last} = 0
                if (@replace && !defined($got{name}));

            if (lc($got{section}) eq lc($args{from})) {
                if (defined $got{name}) {
                    # if we're removing rather than replacing and
                    # there was a previous section match, increase
                    # its length so it will kill this variable
                    # assignment too
                    if ($prev_matched && !defined $args{to} ) {
                        $replace[-1]->{length} += ($got{offset} + $got{length})
                            - ($replace[-1]{offset} + $replace[-1]->{length});
                    }
                }
                else {
                    # if we're removing rather than replacing, increase
                    # the length of the previous match so when it's
                    # replaced it will kill all the way up to the
                    # beginning of this next section (this will kill
                    # any leading whitespace on the line of the
                    # next section, but that's OK)
                    $replace[-1]->{length} += $got{offset} -
                        ($replace[-1]->{offset} + $replace[-1]->{length})
                        if @replace && $prev_matched && !defined($args{to});

                    push @replace, {offset => $got{offset}, length =>
                        $got{length}, section_is_last => 1};
                    $prev_matched = 1;
                }
            }
            else {
                # if we're removing rather than replacing and there was
                # a previous section match, increase its length to kill all
                # the way up to this non-matching section (takes care
                # of newlines between here and there, etc.)
                $replace[-1]->{length} += $got{offset} -
                    ($replace[-1]->{offset} + $replace[-1]->{length})
                    if @replace && $prev_matched && !defined($args{to});
                $prev_matched = 0;
            }
        },
        error    => sub {
            die "Error parsing $args{filename}, near:\n@_\n";
        },
    );
    die "No such section '$args{from}'\n"
        unless @replace;

    # if the string we're replacing with is not the same length as what's
    # being replaced, any offsets following will be wrong. save the difference
    # between the lengths here and add it to any offsets that follow.
    my $difference = 0;

    # rename ALL section headers that matched to
    # (there may be more than one)
    my $replace_with = defined $args{to} ?
        $self->format_section( section => $args{to}, bare => 1 ) : '';

    for my $header (@replace) {
        substr(
            $c,
            $header->{offset} + $difference,
            # if we're removing the last section, just kill all the way to the
            # end of the file
            !defined($args{to}) && $header->{section_is_last} ? length($c) -
                ($header->{offset} + $difference) : $header->{length},
            $replace_with,
        );
        $difference += (length($replace_with) - $header->{length});
    }

    return _write_config($args{filename}, $c);
    # release lock
    close $fh;
}

sub remove_section {
    my $self = shift;

    my (%args) = (
        section     => undef,
        filename    => undef,
        @_
    );

    die "No section given to remove\n" unless $args{section};

    # remove section is just a rename to nothing
    return $self->rename_section( from => $args{section}, filename =>
        $args{filename} );
}

1;

__END__

=head1 NAME

Config::GitLike - git-compatible config file parsing

=head1 SYNOPSIS

This module parses git-style config files, which look like this:

    [core]
        repositoryformatversion = 0
        filemode = true
        bare = false
        logallrefupdates = true
    [remote "origin"]
        url = spang.cc:/srv/git/home.git
        fetch = +refs/heads/*:refs/remotes/origin/*
    [another-section "subsection"]
        key = test
        key = multiple values are OK
        emptyvalue =
        novalue

Code that uses this config module might look like:

    use Config::GitLike;

    my $c = Config::GitLike->new(confname => 'config');
    $c->load;

    $c->get( key => 'section.name' );
    # make the return value a Perl true/false value
    $c->get( key => 'core.filemode', as => 'bool' );

    # replace the old value
    $c->set(
        key => 'section.name',
        value => 'val1',
        filename => '/home/user/.config',
    );

    # make this key have multiple values rather than replacing the
    # old value
    $c->set(
        key => 'section.name',
        value => 'val2',
        filename => '/home/user/.config',
        multiple => 1,
    );

    # replace all occurrences of the old value for section.name with a new one
    $c->set(
        key => 'section.name',
        value => 'val3',
        filename => '/home/user/.config',
        multiple => 1,
        replace_all => 1,
    );

    # make sure to reload the config files before reading if you've set
    # any variables!
    $c->load;

    # get only the value of 'section.name' that matches '2'
    $c->get( key => 'section.name', filter => '2' );
    $c->get_all( key => 'section.name' );
    # prefixing a search regexp with a ! negates it
    $c->get_regexp( key => '!na' );

    $c->rename_section(
        from => 'section',
        to => 'new-section',
        filename => '/home/user/.config'
    );

    $c->remove_section(
        section => 'section',
        filename => '/home/user/.config'
    );

    # unsets all instances of the given key
    $c->set( key => 'section.name', filename => '/home/user/.config' );

    my %config_vals = $config->dump;
    # string representation of config data
    my $str = $config->dump;
    # prints rather than returning
    $config->dump;

=head1 DESCRIPTION

This module handles interaction with configuration files of the style used
by the version control system Git. It can both parse and modify these
files, as well as create entirely new ones.

You only need to know a few things about the configuration format in order
to use this module. First, a configuration file is made up of key/value
pairs. Every key must be contained in a section. Sections can have
subsections, but they don't have to. For the purposes of setting and
getting configuration variables, we join the section name,
subsection name, and variable name together with dots to get a key
name that looks like "section.subsection.variable". These are the
strings that you'll be passing in to C<key> arguments.

Configuration files inherit from each other. By default, C<Config::GitLike>
loads data from a system-wide configuration file, a per-user
configuration file, and a per-directory configuration file, but by
subclassing and overriding methods you can obtain any combination of
configuration files. By default, configuration files that don't
exist are just skipped.

See
L<http://www.kernel.org/pub/software/scm/git/docs/git-config.html#_configuration_file>
for details on the syntax of git configuration files. We won't waste pixels
on the nitty gritty here.

While the behaviour of a couple of this module's methods differ slightly
from the C<git config> equivalents, this module can read any config file
written by git. The converse is usually true, but only if you don't take
advantage of this module's increased permissiveness when it comes to key
names. (See L<DIFFERENCES FROM GIT-CONFIG> for details.)

This is an object-oriented module using L<Any::Moose|Any::Moose>. All
subroutines are object method calls.

A few methods have parameters that are always used for the same purpose:

=head2 Filenames

All methods that change things in a configuration file require a filename to
write to, via the C<filename> parameter. Since a C<Config::GitLike> object can
be working with multiple config files that inherit from each other, we don't
try to figure out which one to write to automatically and let you specify
instead.

=head2 Casting

All get and set methods can make sure the values they're returning or
setting are valid values of a certain type: C<bool>, C<int>,
C<num>, or C<bool-or-int> (or at least as close as Perl can get
to having these types). Do this by passing one of these types
in via the C<as> parameter. The set method, if told to write
bools, will always write "true" or "false" (not anything else that
C<cast> considers a valid bool).

Methods that are told to cast values will throw exceptions if
the values they're trying to cast aren't valid values of the
given type.

See the L<"cast"> method documentation for more on what is considered valid
for each type.

=head2 Filtering

All get and set methods can filter what values they return via their
C<filter> parameter, which is expected to be a string that is a valid
regex. If you want to filter items OUT instead of IN, you can
prefix your regex with a ! and that'll do the trick.

Now, on the the methods!

=head1 MAIN METHODS

There are the methods you're likely to use the most.

=head2 new( confname => 'config' )

Create a new configuration object with the base config name C<confname>.

C<confname> is used to construct the filenames that will be loaded; by
default, these are C</etc/confname> (global configuration file),
C<~/.confname> (user configuration file), and C<<Cwd>/.confname> (directory
configuration file).

You can override these defaults by subclassing C<Config::GitLike> and
overriding the methods C<global_file>, C<user_file>, and C<dir_file>. (See
L<"METHODS YOU MAY WISH TO OVERRIDE"> for details.)

If you wish to enforce only being able to read/write config files that
git can read or write, pass in C<compatible =E<gt> 1> to this
constructor. The default rules for some components of the config
file are more permissive than git's (see L<"DIFFERENCES FROM GIT-CONFIG">).

=head2 confname

The configuration filename that you passed in when you created
the C<Config::GitLike> object. You can change it if you want by
passing in a new name (and then reloading via L<"load">).

=head2 load

Load the global, local, and directory configuration file with the filename
C<confname>(if they exist). Configuration variables loaded later
override those loaded earlier, so variables from the directory
configuration file have the highest precedence.

Pass in an optional path, and it will be passed on to L<"load_dirs"> (which
loads the directory configuration file(s)).

Returns a hash copy of all loaded configuration data stored in the module
after the files have been loaded, or a hashref to this hash in
scalar context.

=head2 config_filenames

An array reference containing the absolute filenames of all config files
that are currently loaded.

=head2 get

Parameters:

    key => 'sect.subsect.key'
    as => 'int'
    filter => '!foo

Return the config value associated with C<key> cast as an C<as>.

The C<key> option is required (will return undef if unspecified); the C<as>
option is not (will return a string by default). Sections and subsections
are specified in the key by separating them from the key name with a .
character. Sections, subsections, and keys may all be quoted (double or
single quotes).

If C<key> doesn't exist in the config, undef is returned. Dies with
the exception "Multiple values" if the given key has more than one
value associated with it. (Use L<"get_all"> to retrieve multiple values.)

Calls L<"load"> if it hasn't been done already. Note that if you've run any
C<set> calls to the loaded configuration files since the last time they were
loaded, you MUST call L<"load"> again before getting, or the returned
configuration data may not match the configuration variables on-disk.

=head2 get_all

Parameters:

    key => 'section.sub'
    filter => 'regex'
    as => 'int'

Like L<"get"> but does not fail if the number of values for the key is not
exactly one.

Returns a list of values (or an arrayref in scalar context).

=head2 get_regexp

Parameters:

    key => 'regex'
    filter => 'regex'
    as => 'bool'

Similar to L<"get_all"> but searches for values based on a key regex.

Returns a hash of name/value pairs (or a hashref in scalar context).

=head2 dump

In scalar context, return a string containing all configuration data, sorted in
ASCII order, in the form:

    section.key=value
    section2.key=value

If called in void context, this string is printed instead.

In list context, returns a hash containing all the configuration data.

=head2 set

Parameters:

    key => 'section.name'
    value => 'bar'
    filename => File::Spec->catfile(qw/home user/, '.'.$config->confname)
    filter => 'regex'
    as => 'bool'
    multiple => 1
    replace_all => 1

Set the key C<foo> in the configuration section C<section> to the value C<bar>
in the given filename.

Replace C<key>'s value if C<key> already exists.

To unset a key, pass in C<key> but not C<value>.

Returns true on success.

If you need to have a . character in your variable name, you can surround the
name with quotes (single or double): C<key =&gt 'section."foo.bar.com"'>
Don't do this unless you really have to.

=head3 multiple values

By default, set will replace the old value rather than giving a key multiple
values. To override this, pass in C<multiple =E<gt> 1>. If you want to replace
all instances of a multiple-valued key with a new value, you need to pass
in C<replace_all =E<gt> 1> as well.

=head2 group_set

Parameters:

    filename => '/home/foo/.bar'
    args_ref => $ref

Same as L<"set">, but set a group of variables at the same time without
writing to disk separately for each.

C<args_ref> is an array reference containing a list of hash references which
are essentially hashes of arguments to C<set>, excluding the C<filename>
argument since that is specified separately and the same file is used for all
variables to be set at once.

=head2 rename_section

Parameters:

    from => 'name.subname'
    to => 'new.subname'
    filename => '/file/to/edit'

Rename the section existing in C<filename> given by C<from> to the section
given by C<to>.

Throws an exception C<No such section> if the section in C<from> doesn't exist
in C<filename>.

If no value is given for C<to>, the section is removed instead of renamed.

Returns true on success, false if C<filename> didn't exist and thus
the rename did nothing.

=head2 remove_section

Parameters:

    section => 'section.subsection'
    filename => '/file/to/edit

Just a convenience wrapper around L<"rename_section"> for readability's sake.
Removes the given section (which you can do by renaming to nothing as well).

=head1 METHODS YOU MAY WISH TO OVERRIDE

If your application's configuration layout is different from the default, e.g.
if its home directory config files are in a directory within the home
directory (like C<~/.git/config>) instead of just dot-prefixed, override these
methods to return the right directory names. For fancier things like altering
precedence, you'll need to override L<"load"> as well.

=head2 dir_file

Return a string containing the path to a configuration file with the
name C<confname> in a directory. The directory isn't specified here.

=head2 global_file

Return the string C</etc/confname>, the absolute name of the system-wide
configuration file with name C<confname>.

=head2 user_file

Return a string containing the path to a configuration file
in the current user's home directory with filename C<confname>.

=head2 load_dirs

Parameters:

    '/path/to/look/in/'

Load the configuration file with the filename L<"dir_file"> in the current
working directory into the memory or, if there is no config matching
C<dir_file> in the current working directory, walk up the directory tree until
one is found. (No error is thrown if none is found.) If an optional path
is passed in, that directory will be used as the base directory instead
of the working directory.

You'll want to use L<"load_file"> to load config files from your overridden
version of this subroutine.

Returns nothing of note.

=head1 OTHER METHODS

These are mostly used internally in other methods, but could be useful anyway.

=head2 load_global

If a global configuration file with the absolute name given by
L<"global_file"> exists, load its configuration variables into memory.

Returns the current contents of all the loaded configuration variables
after the file has been loaded, or undef if no global config file is found.

=head2 load_user

If a configuration file with the absolute name given by
L<"user_file"> exists, load its config variables into memory.

Returns the current contents of all the loaded configuration variables
after the file has been loaded, or undef if no user config file is found.

=head2 load_file( $filename )

Takes a string containing the path to a file, opens it if it exists, loads its
config variables into memory, and returns the currently loaded config
variables (a hashref).

Note that you ought to only call this subroutine with an argument that you
know exists, otherwise config files that don't exist will be recorded as
havind been loaded.

=head2 parse_content

Parameters:

    content => 'str'
    callback => sub {}
    error => sub {}

Parses the given content and runs callbacks as it finds valid information.

Returns undef on success and C<error($content)> (the original content) on
failure.

C<callback> is called like:

    callback(section => $str, offset => $num, length => $num, name => $str, value => $str)

C<name> and C<value> may be omitted if the callback is not being called on a
key/value pair, or if it is being called on a key with no value.

C<error> is called like:

    error( content => $content, offset => $offset )

Where C<offset> is the point in the content where the parse error occurred.

=head2 set_multiple( $name )

Mark the key string C<$name> as containing multiple values.

Returns nothing.

=head2 is_multiple( $name )

Return a true value if the key string C<$name> contains multiple values; false
otherwise.

=head2 define

Parameters:

    section => 'str'
    name => 'str'
    value => 'str'

Given a section, a key name, and a value¸ store this information
in memory in the config object.

Returns the value that was just defined on success, or undef
if no name is given and thus the key cannot be defined.

=head2 cast

Parameters:

    value => 'foo'
    as => 'int'
    human => 1

Return C<value> cast into the type specified by C<as>.

Valid values for C<as> are C<bool>, C<int>, C<num>, or C<bool-or-num>. For
C<bool>, C<true>, C<yes>, C<on>, C<1>, and undef are translated into a true
value (for Perl); anything else is false. Specifying a true value for the
C<human> arg will get you a human-readable 'true' or 'false' rather than a
value that plays along with Perl's definition of truthiness (0 or 1).

For C<int>s and C<num>s, if C<value> ends in C<k>, C<m>, or C<g>, it will be
multiplied by 1024, 1048576, and 1073741824, respectively, before being
returned. C<int>s are truncated after being multiplied, if they have
a decimal portion.

C<bool-or-int>, as you might have guessed, gives you either
a bool or an int depending on which one applies.

If C<as> is unspecified, C<value> is returned unchanged.

=head2 format_section

Parameters:

    section => 'section.subsection'
    base => 1

Return a string containing the section/subsection header, formatted
as it should appear in a config file. If C<bare> is true, the returned
value is not followed be a newline.

=head2 format_definition

Parameters:

    key => 'str'
    value => 'str'
    bare => 1

Return a string containing the key/value pair as they should be printed in the
config file. If C<bare> is true, the returned value is not tab-indented nor
followed by a newline.

=head1 DIFFERENCES FROM GIT-CONFIG

This module does the following things differently from git-config:

We are much more permissive about valid key names and section names.
For variables, instead of limiting variable names to alphanumeric characters
and -, we allow any characters except for = and newlines, including spaces as
long as they are not leading or trailing, and . as long as the key name is
quoted. For sections, any characters but whitespace, [], and " are allowed.
You can enforce reading/writing only git-compatible variable names and section
headers by passing C<compatible =E<gt> 1> to the constructor.

When replacing variable values and renaming sections, we merely use
a substring replacement rather than writing out new lines formatted in the
default manner for new lines. Git's replacement/renaming (as of
1.6.3.2) is currently buggy and loses trailing comments and variables
that are defined on the same line as a section being renamed. Our
method preserves original formatting and surrounding information.

We also allow the 'num' type for casting, since in many cases we
might want to be more lenient on numbers.

We truncate decimal numbers that are cast to C<int>s, whereas
Git just rejects them.

We don't support NUL-terminating output (the --null flag to
git-config). Who needs it?

=head1 BUGS

If you find any bugs in this module, report them at:

  http://rt.cpan.org/

Include the version of the module you're using and any relevant problematic
configuration files or code snippets.

=head1 SEE ALSO

L<http://www.kernel.org/pub/software/scm/git/docs/git-config.html#_configuration_file>,
L<Config::GitLike::Cascaded|Config::GitLike::Cascaded>

=head1 LICENSE

You may modify and/or redistribute this software under the same terms
as Perl 5.8.8.

=head1 COPYRIGHT

Copyright 2009 Best Practical Solutions, LLC

=head1 AUTHORS

Alex Vandiver <alexmv@bestpractical.com>,
Christine Spang <spang@bestpractical.com>
