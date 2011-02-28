package App::htrepl;

use strict;
use warnings;

use LWP::UserAgent;
use HTTP::Headers;
use HTTP::Cookies;
use URI;
use Term::ReadLine;

use Data::Dumper;

our $VERSION = '0.001_01';

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

    my $filename;
    if ( $uri_str =~ /</ ) { 
        ( $uri_str, $filename ) = $uri_str =~ m{^([\S]+)\s*<\s*(.+)$};
    }

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

    return $self->_do_http( $meth, $path, $filename );
}

sub _do_http { 
    my ( $self, $meth, $path, $filename ) = @_;

    my $uri = sprintf '%s://%s:%s/%s', @{ $self }{'proto', 'host', 'port'}, $path;

    my $msg_body = '';
    if ( $meth =~ /^POST|PUT$/ ) { 
        if ( $filename ) { 
            $msg_body = $self->_read_body_file( $filename );
        } else { 
            $msg_body = $self->_read_body( $meth );
        }
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

sub _read_body_file { 
    my ( $self, $filename ) = @_;

    open my $fh, $filename or die "$filename: $!\n";

    local $/;

    my $body = <$fh>;

    return $body;
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
        look    => \&_cmd_look,
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

sub _cmd_look { 
    my ( $self, $arg ) = @_;

    if ( $arg =~ /^head/i ) { 
        my ( $hdr ) = $arg =~ /head\w*\s+(.+)$/;

        if ( my $val = $self->{headers}->header( $hdr ) ) { 
            print { $self->{outfh} } "$hdr: $val\n";
        } else { 
            print { $self->{outfh} } "No such header $hdr\n";
        }

    } elsif ( $arg =~ /cook/i ) { 
        my ( $ck ) = $arg =~ /cook\w*\s+(.+)$/;

        if ( my $val = $self->_lookup_cookie( $ck ) ) { 
            print { $self->{outfh} } "$ck: $val\n";
        } else { 
            print { $self->{outfh} } "No such cookie $ck\n";
        }
    } else { 
        die "Don't know what to do with [.look $arg]. Try .help\n";
    }

    return '';
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
            $self->{host} = '';
        }

    } elsif ( $arg =~ /^port/i ) { 
        my ( $val ) = $arg =~ /port\s+(\d+)$/;

        if ( defined $val ) { 
            $self->_set_port( $val );
        } else { 
            print { $self->{outfh} } "Unsetting port\n";
            $self->{port} = '';
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

sub _cmd_help { 
    my $self = shift;

    print { $self->{outfh} } <<'END';

htrepl commands:

.header Content-Type application/json    # set header
.header Content-Type                     # remove header

.cookie ID 12345                         # set a cookie
.cookie ID                               # remove a cookie

.set host 127.0.0.1                      # set the current host
.set port 80                             # set the current port
.set ua MyBrowser/1.2.3                  # set user agent

.show headers                            # display response headers
.show body                               # display response body

.hide headers                            # hide response headers
.hide body                               # hide response body

.look header Content-Type                # show current request header
.look cookie ID                          # show current cookie value

.quit (or .q)                            # quit

END

      return '';
}

sub _lookup_cookie { 
    my ( $self, $name ) = @_;

    # Sigh. HTTP::Cookies has no good interface for looking up
    # cookies by name. :(

    my $jar = $self->{cookies};

    my $ret = '';

    $jar->scan( sub { 
        my ( $v, $cname, $val, $p, $domain, $port ) = @_;

        if ( ( $self->{host} =~ /\Q$domain/ ) and ( $name eq $cname ) ) { 
            $ret = $val;
        }
    } );

    return $ret;
}

__PACKAGE__->run unless caller;

1;


__END__


=head1 NAME

App::htrepl - A commandline REPL for HTTP applications

=head1 VERSION

0.001_01 - Development release

=head1 SYNOPSIS

    [friedo@box ~]$ htrepl

    htrepl> head http://www.google.com
    Setting protocol http
    Setting host www.google.com
    Setting port 80
    
    
    HEAD http://www.google.com:80/
    
    200 OK
    Cache-Control: private, max-age=0
    Connection: close
    Date: Mon, 28 Feb 2011 05:23:23 GMT
    Server: gws
    Content-Type: text/html; charset=ISO-8859-1
    Expires: -1
    Client-Date: Mon, 28 Feb 2011 05:23:23 GMT
    Client-Peer: 72.14.204.103:80
    Client-Response-Num: 1
    Set-Cookie: PREF=ID=1a1bda55cfcf6aa9:FF=0:TM=1298870603:LM=1298870603:S=t8tAuy45KBiOTiuw; expires=Wed, 27-Feb-2013 05:23:23 GMT; path=/; domain=.google.com
    Set-Cookie: NID=44=foHo3p-6-ZXByOkR4TkQOA9EveVk49TQ1jhVthq8HK14LTFN4Vhh92nckgxjBqUfDD3yvzv0vny0q49RnxzpzXdIpNBpXb8Npy9msDN8u8ZtIA01Kub7DGV0s0oWrJw8; expires=Tue, 30-Aug-2011 05:23:23 GMT; path=/; domain=.google.com; HttpOnly
    X-XSS-Protection: 1; mode=block

=head1 DESCRIPTION

App::htrepl provides a commandline tool, C<htrepl>, which implements a REPL (read-eval-print loop) for talking to HTTP
applications. C<htrepl> provides commands for making HTTP requests, manipulating headers and cookies, and other
functions in an interactive environment. It will even preserve command history, if you have a proper C<readline> 
installed.

=head1 REPOSITORY

L<https://github.com/friedo/app-htrepl>

=head1 AUTHOR

Mike Friedman <friedo at friedo dot com>

=head1 COPYRIGHT & LICENSE 

Copyright (C) 2011 by Mike Friedman

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.4 or,
at your option, any later version of Perl 5 you may have available.

=cut

