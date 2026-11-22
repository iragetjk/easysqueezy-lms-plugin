package Plugins::EasySqueezy::ZeroTier;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# ZeroTier on the server: detected and reported, never installed (it needs administrator rights
# and its own network interface, unlike Tailscale's userspace mode).
#
# Everything is read the way Lyrion's own user can: ZeroTier's local API needs a token only
# root can read, so instead: its home folder (identity.public: the node ID; networks.d/*.conf:
# the networks joined, both readable on Linux and FreeBSD installs), whether it answers on its
# port, and the network interfaces with their IPv4 addresses (`ip` or `ifconfig`). Which
# interface belongs to which network follows from ZeroTier's own naming (see _devNames), so the
# app can match its network ID even where the network files can't be read.

use strict;

use File::Spec::Functions qw(catdir catfile);
use IO::Socket::INET;

use Slim::Utils::Log;
use Slim::Utils::Misc;

my $log = logger('plugin.easysqueezy');

my @HOMES = (
	'/var/lib/zerotier-one',                              # Linux
	'/var/db/zerotier-one',                               # FreeBSD
	'/Library/Application Support/ZeroTier/One',          # macOS
);

sub _home {
	for my $dir (@HOMES) { return $dir if -d $dir }
	return '';
}

sub _readFile {
	my $file = shift;
	open(my $fh, '<', $file) or return '';
	local $/;
	my $s = <$fh> // '';
	close $fh;
	return $s;
}

# The interface names ZeroTier gives network $nwid (hex): Linux "zt" + base32 of a 40-bit fold
# (LinuxEthernetTap.cpp), FreeBSD "zt" + the 64-bit id in base32hex (13 characters).
sub _devNames {
	my $hex = lc(shift);
	return () unless $hex =~ /^[0-9a-f]{16}$/;
	require Math::BigInt;
	my $n = Math::BigInt->from_hex($hex);

	my @linux;
	my $alpha = 'abcdefghijklmnopqrstuvwxyz234567';
	my $mask40 = Math::BigInt->from_hex('ffffffffff');
	my $fold = ($n->copy->bxor($n->copy->brsft(24)))->band($mask40);
	my $name = 'zt';
	for my $i (reverse 0 .. 7) {
		$name .= substr($alpha, $fold->copy->brsft(5 * $i)->band(31)->numify, 1);
	}
	push @linux, $name;

	my $hexalpha = '0123456789abcdefghijklmnopqrstuv';
	my $bsd = 'zt' . substr($hexalpha, $n->copy->brsft(60)->band(15)->numify, 1);
	for my $i (reverse 0 .. 11) {
		$bsd .= substr($hexalpha, $n->copy->brsft(5 * $i)->band(31)->numify, 1);
	}
	return (@linux, $bsd);
}

# zt* interfaces => [IPv4 addresses].
sub _interfaces {
	my %ifs;
	my $ip = Slim::Utils::Misc::findbin('ip') || (-x '/sbin/ip' ? '/sbin/ip' : -x '/usr/sbin/ip' ? '/usr/sbin/ip' : '');
	if ($ip && $^O eq 'linux') {
		for my $line (`$ip -o -4 addr show 2>/dev/null`) {
			next unless $line =~ /^\d+:\s+(zt\w+)\s+inet\s+([\d.]+)\//;
			push @{ $ifs{$1} }, $2;
		}
		for my $line (`$ip -o link show 2>/dev/null`) {
			$ifs{$1} ||= [] if $line =~ /^\d+:\s+(zt\w+)[:@]/;
		}
		return \%ifs;
	}
	my $ifconfig = -x '/sbin/ifconfig' ? '/sbin/ifconfig' : Slim::Utils::Misc::findbin('ifconfig');
	return \%ifs unless $ifconfig;
	my $cur;
	for my $line (`$ifconfig -a 2>/dev/null`) {
		if ($line =~ /^(\S+?):?\s/) { $cur = $1; $ifs{$cur} ||= [] if $cur =~ /^zt/; next }
		next unless $cur && $cur =~ /^zt/;
		push @{ $ifs{$cur} }, $1 if $line =~ /^\s+inet (?:addr:)?([\d.]+)/;
	}
	return \%ifs;
}

# ZeroTier answers on its local port (TCP, any reply means it's running).
sub _running {
	my $home = shift;
	my $port = $home ? _readFile(catfile($home, 'zerotier-one.port')) : '';
	$port = 9993 unless $port =~ /^\s*(\d+)/ && ($port = $1);
	my $s = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 1);
	return 0 unless $s;
	close $s;
	return 1;
}

# { installed, running, node, networks => [{ id, dev, ips => [..] }] }; a network's id is ''
# for an interface whose network couldn't be read (the app matches it by name).
sub status {
	my $home = _home();
	my %r = (installed => ($home || Slim::Utils::Misc::findbin('zerotier-one') || Slim::Utils::Misc::findbin('zerotier-cli')) ? 1 : 0);
	$r{running} = _running($home);
	$r{installed} ||= $r{running};
	($r{node}) = _readFile(catfile($home, 'identity.public')) =~ /^([0-9a-f]{10}):/ if $home;
	$r{node} //= '';

	my @ids;
	if ($home && opendir(my $dh, catdir($home, 'networks.d'))) {
		@ids = sort grep { /^[0-9a-f]{16}$/ } map { /^([0-9a-f]{16})\.conf$/ ? $1 : () } readdir($dh);
		closedir $dh;
	}
	# Names kept from older versions ("devicemap": nwid=device), where readable.
	my %devicemap = map { /^([0-9a-f]{16})=(\S+)/ ? ($1 => $2) : () } split /\n/, ($home ? _readFile(catfile($home, 'devicemap')) : '');

	my $all = _interfaces();
	my %taken;
	my @networks;
	for my $id (@ids) {
		my ($dev) = grep { exists $all->{$_} } (($devicemap{$id} // ()), _devNames($id));
		$taken{$dev} = 1 if $dev;
		push @networks, { id => $id, dev => $dev // '', ips => $dev ? $all->{$dev} : [] };
	}
	for my $dev (sort keys %$all) {
		next if $taken{$dev};
		push @networks, { id => '', dev => $dev, ips => $all->{$dev} };
	}
	$r{networks} = \@networks;
	$r{installed} ||= @networks ? 1 : 0;
	return \%r;
}

1;
