package App::htrepl;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Cookies;
use URI;
use Term::ReadLine;

use Data::Dumper;

our $VERSION = '0.001';

sub new { 
    my ( $class, %args ) = @_;

    $args{$_} ||= '' for 'host', 'proto', 'port';

    return bless \%args, $class;
}

sub run { 
    my $self = shift;

    $self->{term}  = Term::ReadLine->new( 'htrepl' );
    $self->{outfh} = $self->{term}->OUT || \*STDOUT;
    $self->{infh}  = $self->{term}->IN  || \*STDIN;

    $self->{user_agent} = 'perl-htrepl/' . $VERSION;
    $self->{headers}    = HTTP::Headers->new;
    $self->{cookies}    = HTTP::Cookies->new;

    $self->{show_headers} = 1;
    $self->{show_body}    = 1;

    while( defined ( my $line = $self->{term}->readline( 'htrepl> ' ) ) ) { 
        $self->{term}->addhistory( $line ) if $line =~ /\S/;

        my $res = eval { 
            $self->_eval( $line );
        };

        if ( my $err = $@ ) { 
            print { $self->{outfh} } "ERROR: $err", "\n\n";
            next;
        }

        next unless defined $res;    # commands will print their output directly

        print { $self->{outfh} } $res, "\n\n";

    }
}


sub _eval { 
    my ( $self, $line ) = @_;

    if ( $line =~ /^\./ ) { 
        # commands start with .
        return $self->_process_cmd( $line );
    }

    # otherwise do some http!
    my ( $meth, $uri_str ) = $line =~ m{^\s*(\w+)\s+(.+)$};
    return '' unless $meth;
    $meth = uc $meth;
    
    my $uri = URI->new( $uri_str );

    if ( my $scheme = $uri->scheme ) { 
        $self->_set_proto( $scheme );
    }

    if ( $uri->can( 'host' ) ) { 
        $self->_set_host( $uri->host );
    }

    if ( $uri->can( 'port' ) ) { 
        $self->_set_port( $uri->port );
    }

    my $path = ( $uri->path_query || '' );
   
    # everything we need?
    $self->_check_reqs;

    return $self->_do_http( $meth, $path );
}

sub _do_http { 
    my ( $self, $meth, $path ) = @_;

    my $uri = sprintf '%s://%s:%s/%s', @{ $self }{'proto', 'host', 'port'}, $path;

    my $msg_body = '';
    if ( $meth =~ /^POST|PUT$/ ) { 
        $msg_body = $self->_read_body( $meth );
    }

    print { $self->{outfh} } "\n\n$meth $uri\n\n";
    my $req = HTTP::Request->new( $meth, $uri, $self->{headers} );
    $req->content( $msg_body );

    my $ua = LWP::UserAgent->new;

    $ua->agent( $self->{user_agent} );
    $ua->cookie_jar( $self->{cookies} );

    my $res = $ua->simple_request( $req );

    my $ret = $res->status_line . "\n";

    if ( $self->{show_headers} ) { 
        $ret .= $res->headers->as_string;
    }

    if ( $self->{show_body} ) { 
        $ret .= $res->content;
    }

    return $ret;
}

sub _read_body {
    my ( $self, $meth ) = @_;

    print { $self->{outfh} } "Enter $meth body data. Terminate with CTRL-d\n\n";
    my $ret = '';

    while ( 1 ) { 
        my $line = $self->{term}->readline( "$meth> " ); 
        last unless defined $line;
        $ret .= $line;
    }

    return $ret;
}

sub _set_proto { 
    my ( $self, $scheme ) = @_;

    unless( $scheme =~ /^https?/ ) { 
        die "Don't know what to do with URI protocol [$scheme]. Try http or https.\n";
    }

    if ( $scheme ne $self->{proto} ) { 
        print { $self->{outfh} } "Setting protocol $scheme\n";
        $self->{proto} = $scheme;
    }
}

sub _set_host { 
    my ( $self, $host ) = @_;

    if ( $host ne $self->{host} ) { 
        print { $self->{outfh} } "Setting host $host\n";
        $self->{host} = $host;
    }
}

sub _set_port { 
    my ( $self, $port ) = @_;

    if ( $port ne $self->{port} ) { 
        print { $self->{outfh} } "Setting port $port\n";
        $self->{port} = $port;
    }
}

sub _check_reqs { 
    my $self = shift;

    unless( $self->{proto} ) { 
        $self->_set_proto( 'http' );
    }

    unless( $self->{port} ) { 
        $self->_set_port( 80 );
    }

    unless( $self->{host} ) { 
        die "No hostname specified.\n";
    }
}
    

sub _process_cmd { 
    my ( $self, $line ) = @_;

    my %cmds = 
      ( q       => \&_cmd_quit,
        quit    => \&_cmd_quit,
        set     => \&_cmd_set,
        cookie  => \&_cmd_cookie,
        header  => \&_cmd_header,
        help    => \&_cmd_help,
        hide    => \&_cmd_show_hide,
        show    => \&_cmd_show_hide,
      );

    my ( $cmd, $arg ) = $line =~ m{^\.(\w+)(?:\s+)?(.+)?$};

    unless( exists $cmds{lc $cmd} ) { 
        die "Unknown command [$cmd]. Try .help\n";
    }

    my @args;
    if ( $cmd =~ /^show|hide$/ ) { 
        push @args, lc $cmd;
    }

    my $meth = $cmds{$cmd};
    $self->$meth( $arg, @args );
}

sub _cmd_quit { 
    exit;
}

sub _cmd_show_hide { 
    my ( $self, $arg, $cmd ) = @_;

    my $field;
    if ( $arg =~ /head/i ) { 
        $field = 'headers';
    } elsif ( $arg =~ /bod/i ) { 
        $field = 'body';
    } else { 
        die "Don't know how to $cmd [$arg]. Try .help\n";
    }

    my $key = 'show_' . $field;
    $self->{$key} = $cmd eq 'show' ? 1 : 0;

    print { $self->{outfh} } ( $cmd eq 'show' ? 'Showing ' : 'Hiding ' ), $field;
    return '';
}

sub _cmd_set { 
    my ( $self, $arg ) = @_;

    if ( $arg =~ /^host/i ) { 
        my ( $val ) = $arg =~ /host\s+(.+)$/;

        if ( defined $val ) { 
            $self->_set_host( $val );
        } else { 
            print { $self->{outfh} } "Unsetting host\n";
            delete $self->{host};
        }

    } elsif ( $arg =~ /^port/i ) { 
        my ( $val ) = $arg =~ /port\s+(\d+)$/;

        if ( defined $val ) { 
            $self->_set_port( $val );
        } else { 
            print { $self->{outfh} } "Unsetting port\n";
            delete $self->{port};
        }

    } elsif ( $arg =~ /^ua/i ) { 
        my ( $val ) = $arg =~ /ua\s+(.+)$/;
        unless( $val ) { 
            die "Can't set User-Agent [$val]\n";
        }

        print { $self->{outfh} } "Setting User-Agent $val\n";
        $self->{user_agent} = $val;
    } else { 
        die "Don't know what to do with [.set $arg]. Try .help\n";
    }

    return '';
}

sub _cmd_cookie { 
    my ( $self, $arg ) = @_;

    die "Can't set cookie without a hostname. Set a host or make a request first.\n"
      unless $self->{host};

    my ( $cookie ) = $arg =~ m{^([\w\d-]+)};
    my ( $val )    = $arg =~ m{^\Q$cookie\E\s+(.+)$};

    unless ( $cookie ) { 
        die "Can't understand cookie name $cookie\n";
    }

    if ( defined $val ) { 
        print { $self->{outfh} } "Setting cookie $cookie => $val\n";
        
        # I think we need to do something special to support SSL?
        $self->{cookies}->set_cookie( 1, $cookie, $val, '/', $self->{host}, $self->{port}, 0, 0, 86400 );
        return '';
    }

    # no value == delete
    print { $self->{outfh} } "Deleting cookie $cookie";
    $self->{cookies}->clear( $self->{host}, '/', $cookie );
    return '';
}

sub _cmd_header { 
    my ( $self, $arg ) = @_;

    my ( $header ) = $arg =~ m{^([\w\d-]+)};
    my ( $val )    = $arg =~ m{^\Q$header\E\s+(.+)$};

    unless( $header ) { 
        die "Can't understand header name $header\n";
    }

    if ( defined $val ) { 
        print { $self->{outfh} } "Setting header $header => $val\n";
        $self->{headers}->header( $header => $val );
        return '';
    } 

    # no value == delete
    print { $self->{outfh} } "Deleting header $header\n";
    $self->{headers}->remove_header( $header );
    return '';
}


__PACKAGE__->run unless caller;

1;


__END__

