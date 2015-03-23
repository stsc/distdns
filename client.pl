#!/usr/bin/perl
#
# Copyright (c) 2013, 2015 Michel Ketterle, Steven Schubiger
#
# This file is part of distdns.
#
# distdns is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# distdns is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with distdns.  If not, see <http://www.gnu.org/licenses/>.

use strict;
use warnings;
use constant false => 0;

BEGIN
{
    my @modules = (
        [ 'Config::Tiny',          [                                           ] ],
        [ 'Digest::MD5',           [ qw(md5_hex)                               ] ],
        [ 'Fcntl',                 [ qw(:flock)                                ] ],
        [ 'File::Spec::Functions', [ qw(catfile rel2abs)                       ] ],
        [ 'FindBin',               [ qw($Bin)                                  ] ],
        [ 'Getopt::Long',          [ qw(:config no_auto_abbrev no_ignore_case) ] ],
        [ 'JSON',                  [ qw(decode_json)                           ] ],
        [ 'LWP::UserAgent',        [                                           ] ],
        [ 'POSIX',                 [ qw(strftime)                              ] ],
        [ 'Sys::Hostname',         [ qw(hostname)                              ] ],
        [ 'Tie::File',             [                                           ] ],
    );
    my (@missing, @import);
    foreach my $module (@modules) {
        unless (eval "require $module->[0]; 1") {
            push @missing, $module->[0];
            next;
        }
        unless (eval { $module->[0]->import(@{$module->[1]}); 1 }) {
            push @import, $module->[0];
        }
    }
    if (@missing || @import) {
        warn <<"EOT";
Modules missing: @missing
Import failures: @import
EOT
        exit 1;
    }
}

my $VERSION = '0.07';

my $conf_file = catfile($Bin, 'client.conf');

sub _die { die "$0: [client] $_[0]" }

sub usage
{
    warn "$_[0]\n" if defined $_[0];
    print <<"USAGE";
Usage: $0 [options]
    -d, --debug    server debugging
    -h, --help     this help screen
    -i, --init     initialize session data
    -l, --list     list remote entries
USAGE
    exit;
}

my %opts;
GetOptions(\%opts, qw(d|debug h|help i|init l|list)) or usage();
usage() if $opts{h};

usage('Cannot combine --init and --list') if $opts{i} && $opts{l};

my $config = Config::Tiny->new;
   $config = Config::Tiny->read($conf_file);

my $get_config_opts = sub
{
    my ($section, $options) = @_;

    _die "Section '$section' missing in $conf_file\n" unless exists $config->{$section};

    my %options;
    @options{@$options} = @{$config->{$section}}{@$options};

    foreach my $option (@$options) {
        _die "Option '$option' not set in $conf_file\n" unless defined $options{$option} && length $options{$option};
    }

    return @options{@$options};
};

my ($hosts_file, $session_file) = map rel2abs($_, $Bin), $get_config_opts->('path', [ qw(hosts_file session_file) ]);

my ($server_url)  = $get_config_opts->('url',  [ qw(server_url) ]);
my ($netz, $name) = $get_config_opts->('data', [ qw(netz name)  ]);

my $save_session = sub
{
    my ($session) = @_;

    open(my $fh, '>', $session_file) or _die "Cannot open $session_file for writing: $!\n";
    print {$fh} "$session\n";
    close($fh);
};

my $get_session = sub
{
    open(my $fh, '<', $session_file) or _die "Cannot open $session_file for reading: $!\nPerhaps try running --init\n";
    chomp(my $session = <$fh>);
    close($fh);

    return $session;
};

my $session = $opts{i} ? substr(md5_hex(md5_hex(time() . {} . rand() . $$)), 0, 32) : $get_session->();

my %params = (
    netz    => $netz,
    pc      => hostname(),
    name    => $name,
    debug   => $opts{d} || false,
    init    => $opts{i} || false,
    list    => $opts{l} || false,
    session => $session,
);

my $ua = LWP::UserAgent->new;

my $response = $ua->post($server_url, \%params);

if ($response->is_success) {
    my $data;

    eval {
        $data = decode_json($response->decoded_content);
    } or exit;

    die "$0: [server] $data->{error}" if defined $data->{error};

    if ($opts{i}) {
        $save_session->($session);
    }
    elsif ($opts{l}) {
        format STDOUT_TOP =
IP                 Name               PC                      Netz               Aktualisiert
====================================================================================================
.
        foreach my $entry (sort { $a->{netz} cmp $b->{netz} } @{$data->{entries}}) {
            my $updated = strftime '%Y-%m-%d %H:%M:%S', localtime $entry->{time};
            format STDOUT =
@<<<<<<<<<<<<<<    @<<<<<<<<<<<<<<    @<<<<<<<<<<<<<<<<<<<    @<<<<<<<<<<<<<<    @<<<<<<<<<<<<<<<<<<
@$entry{qw(ip name pc netz)}, $updated
.
            write;
        }
    }
    else {
        my %list;
        foreach my $entry (@{$data->{entries}}) {
            my $host = "$entry->{ip}\t" . join '.', @$entry{qw(name pc netz)};
            push @{$list{$entry->{netz}}}, $host;
        }

        my $o = tie my @hosts, 'Tie::File', $hosts_file or _die "Cannot tie $hosts_file: $!\n";
        $o->flock(LOCK_EX);

        foreach my $network (keys %list) {
            my %indexes;
            for (my $i = 0; $i < @hosts; $i++) {
                if ($hosts[$i] =~ /^\#$network\#$/i) {
                    $indexes{start} = $i;
                }
                elsif (exists $indexes{start} && $hosts[$i] =~ /^\#\/$network\#$/i) {
                    $indexes{end} = $i;
                    my $count = ($indexes{end} - $indexes{start} > 1)
                      ? $indexes{end} - $indexes{start} - 1
                      : 0;
                    splice @hosts, $indexes{start} + 1, $count, @{$list{$network}};
                    last;
                }
            }
        }

        undef $o;
        untie @hosts;
    }
}
else {
    warn $response->status_line, "\n";
}
