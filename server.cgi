#!/usr/bin/perl
#
# Copyright (c) 2013 Michel Ketterle, Steven Schubiger
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
use lib qw(lib);

use CGI ();
use Config::Tiny ();
use Fcntl ':flock';
use File::Spec::Functions qw(catfile rel2abs);
use FindBin qw($Bin);
use JSON qw(decode_json encode_json);

my $VERSION = '0.05';

my $conf_file = catfile($Bin, 'server.conf');

my $query = CGI->new;

my @params = qw(netz pc name debug init session);
my %params;

foreach my $param (@params) {
    $params{$param} = $query->param($param);
}
$params{ip} = $query->remote_addr;

if ($params{debug}) {
    $SIG{__DIE__} = sub
    {
        print $query->header('application/json');
        print encode_json({ entries => [], error => $_[0] });
        exit;
    };
}

my $config = Config::Tiny->new;
   $config = Config::Tiny->read($conf_file);

my $section = 'path';

die "Section $section missing in $conf_file\n" unless exists $config->{$section};

my @options = qw(json_file session_file);

my %options;
@options{@options} = @{$config->{$section}}{@options};

foreach my $option (@options) {
    die "Option $option not set in $conf_file\n" unless defined $options{$option} && length $options{$option};
}

my ($json_file, $session_file) = map rel2abs($options{$_}, $Bin), @options;

if ($params{init}) {
    die "Delete $session_file first\n" if -e $session_file;

    open(my $fh, '>', $session_file) or die "Cannot open $session_file for writing: $!\n";
    print {$fh} "$params{session}\n";
    close($fh);
}
else {
    open(my $fh, '<', $session_file) or die "Cannot open $session_file for reading: $!\nPerhaps try running --init\n";
    my $session = do { local $/; <$fh> };
    chomp $session;
    close($fh);

    die "Session ID mismatch\n" unless $params{session} eq $session;
}

my @missing_params = grep { not defined $params{$_} && length $params{$_} } @params;
if (@missing_params) {
    my $missing_params = join ', ', map "'$_'", @missing_params;
    die "Incomplete query: param(s) $missing_params missing or not defined\n";
}

my %access;
my $access_file = "$params{netz}.conf";

if (-e $access_file) {
    open(my $fh, '<', $access_file) or die "Cannot open $access_file for reading: $!\n";
    while (my $line = <$fh>) {
        chomp $line;
        my ($name, $pc) = split /\s*,\s*/, $line;
        push @{$access{$name}}, $pc;
    }
    close($fh);
}
else {
    die "Access file $access_file does not exist\n";
}

if (exists $access{$params{name}} && grep /^$params{pc}$/i, @{$access{$params{name}}}) {
    open(my $fh, '+<', $json_file) or die "Cannot open $json_file for read/write: $!\n";
    flock($fh, LOCK_EX)            or die "Cannot lock $json_file: $!\n";

    my $json = do { local $/; <$fh> };

    my $data = defined $json && length $json ? decode_json($json) : [];

    for (my $i = 0; $i < @$data; $i++) {
        if ($params{netz} eq $data->[$i]->{netz}
         && $params{pc}   eq $data->[$i]->{pc}
         && $params{name} eq $data->[$i]->{name}) {
            splice @$data, $i--, 1;
        }
    }
    push @$data, { map { $_ => $params{$_} } qw(netz pc name ip) };

    seek($fh, 0, 0)  or die "Cannot seek to start of $json_file: $!\n";
    truncate($fh, 0) or die "Cannot truncate $json_file: $!\n";

    print {$fh} encode_json($data);

    close($fh);

    my @data = grep $_->{netz} eq $params{netz}, @$data;

    print $query->header('application/json');
    print encode_json({ entries => \@data, error => undef });
}
else {
    die "Access not permitted\n";
}
