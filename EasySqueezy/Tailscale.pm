package Plugins::EasySqueezy::Tailscale;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# Remote access for the app: Tailscale run by the plugin, as Lyrion's own user.
#
# Tailscale's official static Linux binaries are downloaded from pkgs.tailscale.com (only when
# the server admin presses Install), checked against their published SHA-256, and run in
# userspace-networking mode: no root, no TUN device, nothing changed in the system's network.
# Connections to the server's tailnet address reach Lyrion on localhost. Everything lives in
# <Lyrion cache dir>/EasySqueezy/tailscale. Updates are offered, never applied without the
# admin. A Tailscale installed on the system by the user is left alone: it is only reported.

use strict;

use File::Path qw(mkpath rmtree);
use File::Spec::Functions qw(catdir catfile);
use IO::Select;
use IO::Socket::UNIX;
use Socket qw(SOCK_STREAM);
use POSIX qw(uname);
use Proc::Background;
use Digest::SHA;
use JSON::XS::VersionOneAndTwo;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant PKGS => 'https://pkgs.tailscale.com/stable/';
use constant WATCH_SECONDS => 30;
use constant UPDATE_CHECK_SECONDS => 24 * 3600;
use constant LOG_MAX_BYTES => 1024 * 1024;

# Where a Tailscale installed on the system listens (left alone, only reported).
my @SYSTEM_SOCKETS = ('/var/run/tailscale/tailscaled.sock', '/run/tailscale/tailscaled.sock');

# Architectures with Tailscale tarballs that we install; others are "untested".
my %TESTED = map { $_ => 1 } qw(amd64 arm64 arm 386);

my $log   = logger('plugin.easysqueezy');
my $prefs = preferences('plugin.easysqueezy');
$prefs->init({ tailscale => 0 });

my $daemon;          # Proc::Background of our tailscaled
my $failures = 0;    # restarts in a row, for back-off
my $nextStart = 0;
my $loginProc;       # Proc::Background of `tailscale up` while logging in
my $authKeyFile;
my %job;             # install/update in progress: { action, step, error }
my $latest;          # newest Tailscale version on pkgs.tailscale.com (daily check)
my $lastError = '';

sub init {
	Slim::Utils::Timers::setTimer(undef, time() + 3, \&_watch);
	Slim::Utils::Timers::setTimer(undef, time() + 60, \&_checkLatest);
}

sub shutdown {
	_stopDaemon();
}

# --- Paths and platform ------------------------------------------------------------------------

sub _base   { catdir(preferences('server')->get('cachedir'), 'EasySqueezy', 'tailscale') }
sub _bin    { catfile(_base(), 'bin', shift) }
sub _sock   { catfile(_base(), 'tailscaled.sock') }
sub _state  { catdir(_base(), 'state') }
sub _logf   { catfile(_base(), 'tailscaled.log') }

sub arch {
	my $m = lc((uname())[4] || '');
	return 'amd64' if $m =~ /^(x86_64|amd64)$/;
	return 'arm64' if $m =~ /^(aarch64|arm64)/;
	return 'arm'   if $m =~ /^arm/;
	return '386'   if $m =~ /^i[3-6]86$/;
	return 'riscv64' if $m eq 'riscv64';
	return $m;
}

# FreeBSD: Tailscale's official FreeBSD build comes from FreeBSD's own package repository (the
# same as `pkg install tailscale`); Tailscale publishes static tarballs for Linux only.
use constant FREEBSD_PKG => '/usr/local/sbin/pkg';
sub _freebsd { $^O eq 'freebsd' }

# 'yes', 'untested' or '' (the plugin doesn't install Tailscale on this platform).
sub platformSupport {
	if (_freebsd()) {
		# pkg itself (not only its bootstrap stub in /usr/sbin) has to be there.
		return '' unless -x FREEBSD_PKG;
		return arch() eq 'amd64' ? 'yes' : arch() eq 'arm64' ? 'untested' : '';
	}
	return '' unless $^O eq 'linux';
	my $a = arch();
	return 'yes' if $TESTED{$a};
	return 'untested' if $a =~ /^(riscv64|mips|mipsle|mips64|mips64le)$/;
	return '';
}

sub installedVersion {
	my $f = catfile(_base(), 'bin', 'VERSION');
	open(my $fh, '<', $f) or return '';
	my $v = <$fh> // '';
	close $fh;
	$v =~ s/\s+//g;
	return (-x _bin('tailscaled') && -x _bin('tailscale')) ? $v : '';
}

sub latestVersion { $latest // '' }

# --- LocalAPI (tailscaled's HTTP API on its unix socket) ---------------------------------------

sub _localapi {
	my ($sock, $path) = @_;
	return undef unless -S $sock;
	my $s = IO::Socket::UNIX->new(Peer => $sock, Type => SOCK_STREAM, Timeout => 2) or return undef;
	print $s "GET $path HTTP/1.0\r\nHost: local-tailscaled.sock\r\n\r\n";
	my $data = '';
	my $start = time();
	my $sel = IO::Select->new($s);
	while (time() - $start < 3) {
		last unless $sel->can_read(1);
		my $n = sysread($s, my $buf, 65536);
		last unless $n;
		$data .= $buf;
	}
	close $s;
	my ($head, $body) = split(/\r\n\r\n/, $data, 2);
	return undef unless $head && $head =~ m{^HTTP/\S+ 200};
	my $json = eval { from_json($body) };
	return $json;
}

sub _systemStatus {
	for my $sock (@SYSTEM_SOCKETS) {
		my $st = _localapi($sock, '/localapi/v0/status');
		return $st if $st;
	}
	# Not visible from here (e.g. Docker with host networking, where the host's Tailscale
	# interface shows but not its socket): an address of Tailscale's range on this machine.
	if (my $ip = _tailscaleAddress()) {
		return { BackendState => 'Running', Self => { TailscaleIPs => [$ip] } };
	}
	return undef;
}

# A local IPv4 address in 100.64.0.0/10 (Tailscale's range), from /proc/net/fib_trie. Our own
# userspace tailscaled creates no interface, so this is always someone else's Tailscale.
sub _tailscaleAddress {
	open(my $fh, '<', '/proc/net/fib_trie') or return '';
	my ($last, $found) = ('', '');
	while (my $line = <$fh>) {
		if ($line =~ /\|--\s+(\d+\.\d+\.\d+\.\d+)/) { $last = $1; next }
		if ($line =~ m{/32 host LOCAL} && $last =~ /^100\.(\d+)\./ && $1 >= 64 && $1 <= 127) {
			$found = $last;
			last;
		}
	}
	close $fh;
	return $found;
}

# --- Status ------------------------------------------------------------------------------------

# state: system (the user's own Tailscale), unsupported, none (not installed), installing,
# stopped (installed, switched off), starting, needs_login, running.
sub status {
	my %r = (
		arch      => arch(),
		support   => platformSupport(),
		version   => installedVersion(),
		latest    => latestVersion(),
		job       => $job{action} ? "$job{action}: $job{step}" : '',
		error     => $job{error} || $lastError,
		enabled   => $prefs->get('tailscale') ? 1 : 0,
	);

	if (my $sys = _systemStatus()) {
		_fill(\%r, $sys);
		$r{state} = 'system';
		# Its own state: Running, or NeedsLogin/Stopped (installed but not connected).
		$r{system_state} = $sys->{BackendState} || '';
		return \%r;
	}

	if ($job{action}) {
		$r{state} = 'installing';
	} elsif (!$r{support} && !$r{version}) {
		$r{state} = 'unsupported';
	} elsif (!$r{version}) {
		$r{state} = 'none';
	} elsif (!$r{enabled}) {
		$r{state} = 'stopped';
	} elsif (my $st = _localapi(_sock(), '/localapi/v0/status')) {
		_fill(\%r, $st);
		my $b = $st->{BackendState} || '';
		$r{state} = $b eq 'Running' ? 'running' : $b eq 'NeedsLogin' || $b eq 'NeedsMachineAuth' || $b eq 'Stopped' ? 'needs_login' : 'starting';
		$r{auth_url} = $st->{AuthURL} || '';
		$r{machine_auth} = $b eq 'NeedsMachineAuth' ? 1 : 0;
	} else {
		$r{state} = 'starting';
	}
	$r{update} = ($r{version} && $r{latest} && _newer($r{latest}, $r{version})) ? 1 : 0;
	return \%r;
}

sub _fill {
	my ($r, $st) = @_;
	my $self = $st->{Self} || {};
	my @ips = @{ $self->{TailscaleIPs} || [] };
	($r->{ip}) = grep { /^\d+\.\d+\.\d+\.\d+$/ } @ips;
	$r->{ip} //= '';
	($r->{dns_name} = $self->{DNSName} || '') =~ s/\.$//;
	$r->{tailnet} = ($st->{CurrentTailnet} || {})->{Name} || '';
	$r->{running_version} = ($st->{Version} || '') =~ s/-.*//r;
}

sub _newer {
	my ($a, $b) = @_;
	my @a = split /\./, $a;
	my @b = split /\./, $b;
	for my $i (0 .. 2) {
		return 1 if ($a[$i] // 0) > ($b[$i] // 0);
		return 0 if ($a[$i] // 0) < ($b[$i] // 0);
	}
	return 0;
}

# --- Running tailscaled ------------------------------------------------------------------------

sub _watch {
	Slim::Utils::Timers::killTimers(undef, \&_watch);
	eval { _ensureRunning() };
	$log->error("EasySqueezy Tailscale: $@") if $@;
	_reapLogin();
	Slim::Utils::Timers::setTimer(undef, time() + WATCH_SECONDS, \&_watch);
}

sub _ensureRunning {
	my $want = $prefs->get('tailscale') && installedVersion() && !$job{action} && !_systemStatus();
	if (!$want) {
		_stopDaemon() if $daemon;
		return;
	}
	return if $daemon && $daemon->alive;
	# Ours from before a Lyrion crash, still answering: use it.
	return if !$daemon && _localapi(_sock(), '/localapi/v0/status');
	return if time() < $nextStart;

	if ($daemon) {
		$failures++;
		my $wait = $failures > 5 ? 600 : 10 * $failures;
		$nextStart = time() + $wait;
		$lastError = "tailscaled stopped unexpectedly (see " . _logf() . ")";
		$log->warn("EasySqueezy Tailscale: tailscaled stopped, starting again in ${wait}s");
		$daemon = undef;
		return;
	}
	_startDaemon();
}

sub _startDaemon {
	mkpath(_state());
	unlink _sock();
	my $logf = _logf();
	unlink $logf if -s $logf && -s $logf > LOG_MAX_BYTES;
	my $cmd = join(' ', map { _q($_) } _bin('tailscaled'), '--tun=userspace-networking',
		'--statedir=' . _state(), '--socket=' . _sock(), '--port=0');
	$daemon = Proc::Background->new({ die_upon_destroy => 1 }, '/bin/sh', '-c', "exec $cmd >> " . _q($logf) . ' 2>&1');
	$log->warn("EasySqueezy Tailscale: started tailscaled " . installedVersion() . ($daemon ? ' (pid ' . $daemon->pid . ')' : ' FAILED'));
	# Reset the back-off once it has kept running for a while.
	Slim::Utils::Timers::setTimer(undef, time() + 120, sub { if ($daemon && $daemon->alive) { $failures = 0; $lastError = '' } });
}

sub _stopDaemon {
	if ($daemon) {
		$daemon->die if $daemon->alive;
		$daemon = undef;
		$log->warn("EasySqueezy Tailscale: stopped tailscaled");
	}
}

# Runs a command, waiting at most $secs (the admin pressed a button and waits for the page).
sub _run {
	my ($secs, @cmd) = @_;
	my $p = Proc::Background->new({ die_upon_destroy => 1 }, '/bin/sh', '-c',
		'exec ' . join(' ', map { _q($_) } @cmd) . ' >> ' . _q(_logf()) . ' 2>&1') or return;
	my $end = time() + $secs;
	select(undef, undef, undef, 0.2) while $p->alive && time() < $end;
	$p->die if $p->alive;
}

sub _q {
	my $s = shift;
	$s =~ s/'/'\\''/g;
	return "'$s'";
}

# --- Login / logout ----------------------------------------------------------------------------

sub _hostname {
	my $h = lc(Slim::Utils::Network::hostName() || 'server');
	$h =~ s/\..*$//;
	$h =~ s/[^a-z0-9-]+/-/g;
	$h =~ s/^-+|-+$//g;
	return 'lyrion-' . ($h || 'server');
}

# Starts `tailscale up`; the login link then shows in status (AuthURL). With an auth key, it is
# passed in a file readable only by Lyrion's user, removed when `up` finishes.
sub login {
	my $authKey = shift;
	return 'not running' unless _localapi(_sock(), '/localapi/v0/status');
	return 'already logging in' if $loginProc && $loginProc->alive;
	my @cmd = (_bin('tailscale'), '--socket=' . _sock(), 'up', '--hostname=' . _hostname(),
		'--accept-dns=false', '--timeout=900s');
	if (defined $authKey && $authKey =~ /\S/) {
		$authKey =~ s/\s+//g;
		$authKeyFile = catfile(_base(), 'authkey.tmp');
		my $old = umask(077);
		open(my $fh, '>', $authKeyFile) or do { umask($old); return "can't write $authKeyFile: $!" };
		print $fh $authKey;
		close $fh;
		umask($old);
		push @cmd, "--auth-key=file:$authKeyFile";
	}
	$loginProc = Proc::Background->new({ die_upon_destroy => 1 }, '/bin/sh', '-c',
		'exec ' . join(' ', map { _q($_) } @cmd) . ' >> ' . _q(_logf()) . ' 2>&1');
	$log->warn("EasySqueezy Tailscale: login started as " . _hostname() . (defined $authKeyFile ? ' (auth key)' : ''));
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&_reapLogin);
	return '';
}

sub _reapLogin {
	return unless $loginProc;
	if (!$loginProc->alive) {
		$loginProc = undef;
		if ($authKeyFile) { unlink $authKeyFile; $authKeyFile = undef }
		return;
	}
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&_reapLogin);
}

sub logout {
	return 'not running' unless _localapi(_sock(), '/localapi/v0/status');
	$loginProc->die if $loginProc && $loginProc->alive;
	_run(20, _bin('tailscale'), '--socket=' . _sock(), 'logout');
	$log->warn("EasySqueezy Tailscale: logged out");
	return '';
}

# --- Install / update / remove ----------------------------------------------------------------

sub install {
	my $action = shift || 'install';
	return 'busy' if $job{action};
	my $support = platformSupport();
	return 'unsupported' unless $support;
	return 'system' if _systemStatus();
	return _installFreeBSD($action) if _freebsd();
	%job = (action => $action, step => 'index');
	_get(PKGS . '?mode=json', undef, sub {
		my $index = eval { from_json(shift) } || {};
		my $file = ($index->{Tarballs} || {})->{arch()};
		my $version = $index->{TarballsVersion};
		return _fail("no Tailscale download for " . arch()) unless $file && $version;
		$latest = $version;
		$job{step} = 'checksum';
		_get(PKGS . "$file.sha256", undef, sub {
			my ($sha) = (shift // '') =~ /([0-9a-f]{64})/;
			return _fail('no checksum published') unless $sha;
			mkpath(_base());
			my $tgz = catfile(_base(), 'download.tgz');
			unlink $tgz;
			$job{step} = "downloading $version";
			_get(PKGS . $file, $tgz, sub { _unpack($tgz, $sha, $version) });
		});
	});
	return '';
}

sub _get {
	my ($url, $saveAs, $done) = @_;
	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $http = shift;
			eval { $done->($saveAs ? undef : $http->content) };
			_fail($@) if $@;
		},
		sub { my ($http, $error) = @_; _fail("download failed: $url: $error") },
		{ timeout => 300, ($saveAs ? (saveAs => $saveAs) : ()) },
	)->get($url);
}

sub _unpack {
	my ($tgz, $sha, $version) = @_;
	$job{step} = 'checking';
	my $digest = Digest::SHA->new(256);
	$digest->addfile($tgz);
	if ($digest->hexdigest ne $sha) {
		unlink $tgz;
		return _fail('checksum mismatch: download discarded');
	}
	$job{step} = 'unpacking';
	my $new = catdir(_base(), 'bin.new');
	rmtree($new);
	mkpath($new);
	my $tar = Slim::Utils::Misc::findbin('tar');
	my $ok;
	if ($tar && -x $tar) {
		$ok = system($tar, '-xzf', $tgz, '-C', $new, '--strip-components=1') == 0;
	}
	if (!$ok) {
		require Archive::Tar;
		my $iter = Archive::Tar->iter($tgz, 1, { filter => qr{/tailscaled?$} });
		while (my $f = $iter->()) {
			(my $name = $f->name) =~ s{.*/}{};
			$f->extract(catfile($new, $name)) or return _fail("can't unpack $name");
		}
	}
	for my $name (qw(tailscale tailscaled)) {
		my $f = catfile($new, $name);
		return _fail("$name missing in the download") unless -s $f;
		chmod 0755, $f;
	}
	for my $extra (glob(catfile($new, '*'))) {
		rmtree($extra) unless $extra =~ m{/tailscaled?$};
	}
	if (open(my $fh, '>', catfile($new, 'VERSION'))) {
		print $fh "$version\n";
		close $fh;
	}
	unlink $tgz;
	_swapIn($version);
}

# bin.new (both programs and VERSION) becomes bin: stop ours, replace, start again (its state
# and login are kept).
sub _swapIn {
	my $version = shift;
	my $new = catdir(_base(), 'bin.new');
	_stopDaemon();
	my $bin = catdir(_base(), 'bin');
	rmtree($bin);
	rename($new, $bin) or return _fail("can't install: $!");
	$log->warn("EasySqueezy Tailscale: $job{action} done, version $version");
	%job = ();
	$lastError = '';
	$failures = 0;
	$nextStart = 0;
	$prefs->set('tailscale', 1);
	_watch();
}

# --- FreeBSD: the package from FreeBSD's repository ----------------------------------------------
#
# pkg runs as Lyrion's user (INSTALL_AS_USER) with its own catalogue and cache in our folder,
# so nothing of the system's packages changes; it checks the repository's signature against
# the keys FreeBSD ships (/usr/share/keys/pkg) and the package's checksum, as for root. The two
# programs are unpacked from the package; catalogue and package are deleted again afterwards.

my $pkgProc;          # Proc::Background of the pkg script
my $pkgDone;          # what to do when it ends

sub _pkgDir { catdir(_base(), 'pkg') }

# Runs [script] (sh, with the pkg environment set) in the background; [done]->(exit code, output).
sub _pkgRun {
	my ($script, $done) = @_;
	my $dir = _pkgDir();
	rmtree($dir);
	mkpath($dir);
	my $sh = catfile($dir, 'run.sh');
	open(my $fh, '>', $sh) or return $done->(1, "can't write $sh: $!");
	print $fh "set -e\n",
		# Lyrion's service may run without /usr/local/sbin (pkg) in its PATH.
		"export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\n",
		"export INSTALL_AS_USER=yes ASSUME_ALWAYS_YES=yes PKG_DBDIR=" . _q(catdir($dir, 'db')) . " PKG_CACHEDIR=" . _q(catdir($dir, 'cache')) . "\n",
		"mkdir -p \"\$PKG_DBDIR\" \"\$PKG_CACHEDIR\"\n",
		"pkg update -q -r FreeBSD-ports\n",
		$script;
	close $fh;
	$pkgDone = $done;
	$pkgProc = Proc::Background->new('/bin/sh', '-c', 'exec /bin/sh ' . _q($sh) . ' > ' . _q(catfile($dir, 'run.log')) . ' 2>&1');
	Slim::Utils::Timers::setTimer(undef, time() + 2, \&_pkgPoll);
}

sub _pkgPoll {
	return unless $pkgProc;
	if ($pkgProc->alive) {
		Slim::Utils::Timers::setTimer(undef, time() + 2, \&_pkgPoll);
		return;
	}
	my $code = ($pkgProc->wait // 0) >> 8;
	undef $pkgProc;
	my $out = '';
	if (open(my $fh, '<', catfile(_pkgDir(), 'run.log'))) { local $/; $out = <$fh> // ''; close $fh }
	my $done = $pkgDone;
	undef $pkgDone;
	rmtree(_pkgDir());    # the catalogue (~50 MB) and the package aren't needed any more
	$done->($code, $out) if $done;
}

sub _installFreeBSD {
	my $action = shift;
	%job = (action => $action, step => 'fetching from the FreeBSD package repository');
	my $new = catdir(_base(), 'bin.new');
	rmtree($new);
	my $out = catdir(_pkgDir(), 'out');
	_pkgRun(join("\n",
		'pkg fetch -y -q -r FreeBSD-ports -o ' . _q($out) . ' tailscale',
		'f=$(ls ' . _q($out) . '/All/Hashed/tailscale-*.pkg ' . _q($out) . '/All/tailscale-*.pkg 2>/dev/null | head -n 1)',
		'test -n "$f"',
		'mkdir -p ' . _q($new),
		'tar -xf "$f" -C ' . _q($new) . q{ -s ',.*/,,' /usr/local/bin/tailscale /usr/local/bin/tailscaled},
		'pkg rquery -r FreeBSD-ports %v tailscale > ' . _q(catfile($new, 'VERSION')),
		''), sub {
		my ($code, $output) = @_;
		if ($code) {
			$output =~ s/\s+$//;
			my @lines = split /\n/, $output;
			return _fail('the FreeBSD package could not be fetched: ' . join(' ', grep { length } @lines[-3 .. -1]));
		}
		my $version = '';
		if (open(my $fh, '<', catfile($new, 'VERSION'))) { $version = <$fh> // ''; close $fh }
		$version =~ s/[_,~].*//s;    # FreeBSD's port revision
		$version =~ s/\s+//g;
		for my $name (qw(tailscale tailscaled)) {
			return _fail("$name missing in the FreeBSD package") unless -s catfile($new, $name);
			chmod 0755, catfile($new, $name);
		}
		if (open(my $fh, '>', catfile($new, 'VERSION'))) { print $fh "$version\n"; close $fh }
		$latest = $version;
		_swapIn($version);
	});
	return '';
}

# The version FreeBSD's repository has now (for the daily update check).
sub _checkLatestFreeBSD {
	return if $pkgProc || $job{action};
	my $file = catfile(_base(), 'latest.txt');
	_pkgRun('pkg rquery -r FreeBSD-ports %v tailscale > ' . _q($file) . "\n", sub {
		my ($code) = @_;
		return if $code;
		if (open(my $fh, '<', $file)) {
			my $v = <$fh> // '';
			close $fh;
			$v =~ s/[_,~].*//s;
			$v =~ s/\s+//g;
			$latest = $v if $v =~ /^\d+\.\d+/;
		}
		unlink $file;
	});
}

sub _fail {
	my $error = shift;
	$error =~ s/\s+$//;
	$log->error("EasySqueezy Tailscale: " . ($job{action} || '') . " failed: $error");
	%job = ();
	$lastError = $error;
}

# Logs out (the node leaves the tailnet), stops and deletes everything of ours.
sub remove {
	return 'busy' if $job{action};
	logout() if _localapi(_sock(), '/localapi/v0/status');
	_stopDaemon();
	$prefs->set('tailscale', 0);
	rmtree(_base());
	$lastError = '';
	$log->warn("EasySqueezy Tailscale: removed");
	return '';
}

sub setEnabled {
	my $on = shift ? 1 : 0;
	$prefs->set('tailscale', $on);
	$failures = 0;
	$nextStart = 0;
	_watch();
}

sub _checkLatest {
	Slim::Utils::Timers::killTimers(undef, \&_checkLatest);
	Slim::Utils::Timers::setTimer(undef, time() + UPDATE_CHECK_SECONDS, \&_checkLatest);
	# Only where it matters: ours is installed.
	return unless installedVersion();
	return _checkLatestFreeBSD() if _freebsd();
	Slim::Networking::SimpleAsyncHTTP->new(
		sub { my $i = eval { from_json(shift->content) }; $latest = $i->{TarballsVersion} if $i && $i->{TarballsVersion} },
		sub {},
		{ timeout => 30 },
	)->get(PKGS . '?mode=json');
}

1;
