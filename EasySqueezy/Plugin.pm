package Plugins::EasySqueezy::Plugin;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# Companion plugin for the EasySqueezy Player Android app.
#
# 0.1: `easysqueezy status` tells the app the plugin is installed, and its version.
# 0.2: `easysqueezy capabilities` tells the app what the server can do for it (MP3
#      and DSD conversion, the programs they need, C-3PO), so it can warn before a
#      Play fails rather than after.
# 0.3: `easysqueezy serverlog from:<epoch> to:<epoch>` gives the server log lines of that
#      span (not those about other players), for the app's Share log. The server admin can
#      switch it off on the plugin's settings page.
# 0.4: the app's own conversion rules. Plugins like C-3PO and SqueezeDSP replace Lyrion's
#      general rules with rules for single players, which can leave a phone without MP3. For
#      each EasySqueezy phone that connects, the plugin adds rules for exactly that phone and
#      model (the first ones Lyrion checks), copied from Lyrion's stock convert.conf, while
#      such a plugin is enabled; and DSD rules (ffmpeg) when the phone has no usable one.
#      C-3PO still removes them for phones it is explicitly enabled for (the admin's choice).
# 0.5: the settings page lists the conversion rules each connected EasySqueezy phone gets: per
#      format the rule used on Wi-Fi and with a bitrate limit (mobile data), where it comes from,
#      and why other rules are passed over.
# 0.6: phones C-3PO is on for (its default for new players) keep C-3PO for lossless and get only
#      the MP3 rules, so mobile data still plays.
# 0.7: Tailscale for remote access, installed and run by the plugin as Lyrion's user (see
#      Tailscale.pm); `easysqueezy tailscale` reports its state and address.
# 0.8: why an EasySqueezy phone's playback stopped (end of the queue, Don't Stop The Music or a
#      dynamic playlist adding nothing, a song that couldn't be opened...), in server.log and
#      `easysqueezy queueend` (QueueEnd.pm).
# 0.9: a song download converted with this player's rules (Download.pm), for the app to fetch
#      the next song again when Lyrion's own download refuses (C-3PO, SqueezeDSP).
# 0.10: pause stays paused: Lyrion no longer resumes a paused or stopped EasySqueezy phone by
#       itself when it reconnects (a stale "playing at power off"; PauseStays.pm).
# 0.11: `easysqueezy restartnext`: stream the queued next song again without touching the one
#       playing (NextSong.pm), for songs the app can't fetch again as a file.
# 0.12: the lossless format each phone chose in the app (PCM, as it is, FLAC 16/44.1), with
#       its rules (lossless-rules.conf): `easysqueezy lossless format:<pcm|asis|flac16>`.
# 0.12.1: the page's Tailscale state line shows (string tokens upper-case, as Lyrion looks them
#       up); a system Tailscale that isn't logged in is reported (system_state) and explained.
# 0.13: Tailscale installed and run on FreeBSD too: the tailscale package from FreeBSD's
#       repository, fetched by pkg as Lyrion's user (Tailscale.pm).
# 0.14: ZeroTier on the server detected (never installed): `easysqueezy zerotier` reports it
#       running, its node and the networks it's a member of with this server's addresses.
# 0.14.1: the settings page shows each phone's lossless format (and PCM while C-3PO is on).
# 0.14.2: licensed under GPL-2.0; published on GitHub (iragetjk/easysqueezy-lms-plugin).
# 0.14.5: MP3 counts as possible only with a rule that can follow a bitrate limit (B): the DSD
#       MP3 rule is added when the phone has only one that can't (SqueezeDSP's), which made Lyrion
#       send DSD as PCM on mobile data; flac_mp3/dsd_mp3 report the same.
# 0.14.4: phones C-3PO is switched on for also get the lossless rule for formats C-3PO doesn't
#       handle (AIFF came as MP3 even on Wi-Fi when its general rules were gone).
# 0.14.3: with no phone connected, the settings page includes the rules the plugin adds for a
#       phone when it connects; formats left with no rule at all are listed, not dropped.
#      The server admin can switch this off on the plugin's settings page.

use strict;
use base qw(Slim::Plugin::Base);

use Slim::Control::Request;
use Slim::Player::TranscodingHelper;
use Slim::Utils::Misc;
use Slim::Utils::Prefs;
use POSIX qw(mktime);
use File::Spec::Functions qw(catfile);
use Slim::Player::Client;
use Slim::Utils::Timers;
use Slim::Utils::Log;
use Slim::Utils::PluginManager;

# Raised whenever the query's answer changes in a way the app must know about.
use constant API_VERSION => 11;

# The formats the app can take (its HELO list): rules are added only for these outputs.
use constant APP_OUTPUTS => qw(pcm mp3 aac);

# Only the end of server.log is read, and the answer is capped (newest lines kept).
use constant LOG_TAIL_BYTES => 4 * 1024 * 1024;
use constant LOG_MAX_BYTES  => 300 * 1024;

# The app's player model (its HELO): conversion rules may be written for it.
use constant APP_MODEL => 'easysqueezy';

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.easysqueezy',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_EASYSQUEEZY',
});

my $version = '';

my $prefs = preferences('plugin.easysqueezy');
$prefs->init({ shareLog => 1, ownRules => 1, pauseStays => 1 });

# Rules added per phone: client id => { profile => 1 }.
my %ownRules;
# Lossless format rules added per phone (lossless-rules.conf): client id => { profile => 1 }.
my %losslessRules;
use constant LOSSLESS_FORMATS => qw(pcm asis flac16);

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(@_);

	my $data = Slim::Utils::PluginManager->dataForPlugin($class);
	$version = $data->{version} if $data;

	if (main::WEBUI) {
		require Plugins::EasySqueezy::Settings;
		Plugins::EasySqueezy::Settings->new;
	}

	# easysqueezy status  ->  plugin, version, api
	Slim::Control::Request::addDispatch(['easysqueezy', 'status'], [0, 1, 0, \&statusQuery]);
	# easysqueezy capabilities  (for the player given with the request, if any)
	Slim::Control::Request::addDispatch(['easysqueezy', 'capabilities'], [0, 1, 0, \&capabilitiesQuery]);
	# easysqueezy serverlog from:<epoch> to:<epoch>  (for the player given with the request)
	Slim::Control::Request::addDispatch(['easysqueezy', 'serverlog'], [0, 1, 1, \&serverLogQuery]);

	# easysqueezy lossless [format:pcm|asis|flac16]  (for the player given)  ->  the phone's
	# lossless format (sets it, and its rules, when given)
	Slim::Control::Request::addDispatch(['easysqueezy', 'lossless'], [1, 0, 1, \&losslessCommand]);

	# easysqueezy zerotier  ->  ZeroTier on this computer: running, node, networks with addresses
	Slim::Control::Request::addDispatch(['easysqueezy', 'zerotier'], [0, 1, 0, \&zeroTierQuery]);
	require Plugins::EasySqueezy::ZeroTier;

	# easysqueezy tailscale  ->  remote access state, address (plugin-run or the system's own)
	Slim::Control::Request::addDispatch(['easysqueezy', 'tailscale'], [0, 1, 0, \&tailscaleQuery]);
	require Plugins::EasySqueezy::Tailscale;
	Plugins::EasySqueezy::Tailscale::init();

	# easysqueezy queueend  (for the player given)  ->  why its playback last stopped
	Slim::Control::Request::addDispatch(['easysqueezy', 'queueend'], [1, 1, 0, \&queueEndQuery]);
	require Plugins::EasySqueezy::QueueEnd;
	Plugins::EasySqueezy::QueueEnd::init();

	# /easysqueezy/song/<track id>.mp3?player=<mac>&bitrate=<kbps>: a song converted with the
	# rules Lyrion uses for this player (its download address only knows the general ones).
	require Plugins::EasySqueezy::Download;
	Plugins::EasySqueezy::Download::init();

	# Pause stays paused: a reconnect doesn't resume a phone paused or stopped (PauseStays.pm).
	require Plugins::EasySqueezy::PauseStays;
	Plugins::EasySqueezy::PauseStays::init();

	# Restart only the queued next song, when its stream broke (NextSong.pm).
	require Plugins::EasySqueezy::NextSong;
	Plugins::EasySqueezy::NextSong::init();

	# Own conversion rules: for each EasySqueezy phone as it connects, and those already here.
	Slim::Control::Request::subscribe(\&_clientEvent, [['client'], ['new', 'reconnect']]);
	# Also every minute: plugins that take over may load, or change their rules, later.
	Slim::Utils::Timers::setTimer(undef, time() + 5, \&_ownRulesForAll);

	main::INFOLOG && $log->is_info && $log->info("EasySqueezy plugin $version started");
}

sub shutdownPlugin {
	Plugins::EasySqueezy::Tailscale::shutdown() if defined &Plugins::EasySqueezy::Tailscale::shutdown;
}

sub version { $version }

sub queueEndQuery {
	my $request = shift;

	if ($request->isNotQuery([['easysqueezy'], ['queueend']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $reports = Plugins::EasySqueezy::QueueEnd::reports($request->client);
	if (my $r = $reports->[0]) {
		# Age rather than a time: the phone's and the server's clocks may differ.
		$request->addResult('age', time() - $r->{time});
		$request->addResult($_, $r->{$_}) for qw(code text index count);
	}
	$request->setStatusDone();
}

sub zeroTierQuery {
	my $request = shift;
	if ($request->isNotQuery([['easysqueezy'], ['zerotier']])) {
		$request->setStatusBadDispatch();
		return;
	}
	my $st = eval { Plugins::EasySqueezy::ZeroTier::status() } || { installed => 0, running => 0, node => '', networks => [] };
	$request->addResult($_, $st->{$_}) for qw(installed running node);
	my $i = 0;
	for my $n (@{ $st->{networks} }) {
		$request->addResultLoop('networks_loop', $i, 'id', $n->{id});
		$request->addResultLoop('networks_loop', $i, 'dev', $n->{dev});
		$request->addResultLoop('networks_loop', $i, 'ips', join(',', @{ $n->{ips} || [] }));
		$i++;
	}
	$request->setStatusDone();
}

sub tailscaleQuery {
	my $request = shift;

	if ($request->isNotQuery([['easysqueezy'], ['tailscale']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $st = Plugins::EasySqueezy::Tailscale::status();
	for my $k (qw(state system_state ip dns_name tailnet version running_version latest update support arch)) {
		$request->addResult($k, $st->{$k} // '');
	}
	$request->setStatusDone();
}

sub statusQuery {
	my $request = shift;

	if ($request->isNotQuery([['easysqueezy'], ['status']])) {
		$request->setStatusBadDispatch();
		return;
	}

	$request->addResult('plugin', 'EasySqueezy');
	$request->addResult('version', $version);
	$request->addResult('api', API_VERSION);
	$request->setStatusDone();
}

# Whether Lyrion can convert $from to $to for this player: the first usable rule in Lyrion's
# own lookup order (this player, any player with this id, this model, everyone), counting
# only rules that are enabled and whose programs are found.
sub _canConvert {
	my ($client, $from, $to, $generalOnly) = @_;

	my $model = $client ? $client->model : APP_MODEL;
	my $id    = $client ? $client->id : undef;
	my @profiles = $generalOnly ? ("$from-$to-*-*") : (
		($id ? ("$from-$to-$model-$id", "$from-$to-*-$id") : ()),
		"$from-$to-$model-*",
		"$from-$to-*-*",
	);
	my $table = Slim::Player::TranscodingHelper::Conversions();
	my $caps  = \%Slim::Player::TranscodingHelper::capabilities;

	for my $profile (@profiles) {
		next unless exists $table->{$profile};
		# As Lyrion does (getConvertCommand2): a rule whose program is missing or that is
		# disabled sends it on to the next profile, not to the numbered extra rules (-1, -2),
		# which it only tries when a rule doesn't fit the stream.
		next unless Slim::Player::TranscodingHelper::checkBin($profile);
		return 1 unless $to eq 'mp3';
		# MP3 is for mobile data, with a bitrate limit: Lyrion then takes only a rule that can
		# follow it (B), from this profile or its numbered extra rules, and otherwise falls
		# back to the first usable rule of any format (usually PCM). A rule without B, such as
		# SqueezeDSP's, doesn't count.
		for (my $i = 0; ; $i++) {
			my $p = $i ? "$profile-$i" : $profile;
			last unless exists $table->{$p};
			return 1 if ($caps->{$p} || {})->{B};
		}
	}

	return 0;
}

sub _hasBin {
	my $name = shift;
	return Slim::Utils::Misc::findbin($name) ? 1 : 0;
}

# --- The app's own conversion rules -----------------------------------------------------------

# Plugins that replace Lyrion's general conversion rules with rules for single players.
my @TAKEOVER = (
	[qr/^Plugins::C3PO::/, 'C-3PO'],
	[qr/^Plugins::SqueezeDSP::/, 'SqueezeDSP'],
);

sub _takeoverPlugins {
	my @enabled = Slim::Utils::PluginManager->enabledPlugins;
	return sort map { $_->[1] } grep { my $re = $_->[0]; grep { $_ =~ $re } @enabled } @TAKEOVER;
}

# All rule entries of a convert.conf-style file: [in, out, type, id, caps, command].
sub _parseRules {
	my $file = shift;
	my @rules;
	open(my $fh, '<', $file) or return ();
	while (my $line = <$fh>) {
		next if $line =~ /^\s*#/ || $line =~ /^\s*$/;
		$line =~ s/#.*$//; $line =~ s/^\s+//; $line =~ s/\s+$//;
		next unless $line =~ /^(\S+)\s+(\S+)\s+(\S+)\s+(\S+)$/;
		my ($in, $out, $type, $id) = ($1, $2, $3, $4);
		my $next = <$fh>;
		my $caps;
		if (defined $next && $next =~ /^\s+#\s+(\S.*)/) {
			$caps = $1;
			$next = <$fh>;
		}
		next unless defined $next;
		(my $command = $next) =~ s/^\s+//;
		$command =~ s/\s+$//;
		next if $command eq '';
		push @rules, [$in, $out, $type, $id, $caps, $command];
	}
	close($fh);
	return @rules;
}

# Rule entries whose player type matches, for any player id, with an output the app takes:
# [in, out, caps, command].
sub _readRules {
	my ($file, $wantType) = @_;
	return map { [$_->[0], $_->[1], $_->[4], $_->[5]] }
		grep { $_->[2] eq $wantType && $_->[3] eq '*' && _appOutput($_->[1]) } _parseRules($file);
}

sub _appOutput {
	my $out = shift;
	return scalar grep { $_ eq $out } APP_OUTPUTS;
}

my @stockRules;
my @dsdRules;
my %stockCommand;    # "in-out-type" => command, from Lyrion's convert.conf

sub _rules {
	if (!@stockRules) {
		for my $dir (Slim::Utils::OSDetect::dirsFor('convert')) {
			my $file = catfile($dir, 'convert.conf');
			next unless -r $file;
			my @all = _parseRules($file);
			@stockRules = map { [$_->[0], $_->[1], $_->[4], $_->[5]] }
				grep { $_->[2] eq '*' && $_->[3] eq '*' && _appOutput($_->[1]) } @all;
			$stockCommand{"$_->[0]-$_->[1]-$_->[2]"} = _norm($_->[5]) for grep { $_->[3] eq '*' } @all;
			last;
		}
		my $data = Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__);
		@dsdRules = _readRules(catfile($data->{basedir}, 'dsd-rules.conf'), APP_MODEL) if $data && $data->{basedir};
	}
	return (\@stockRules, \@dsdRules);
}

sub _norm {
	my $s = shift // '';
	$s =~ s/\s+/ /g;
	$s =~ s/^ | $//g;
	return $s;
}

sub _ownRulesForAll {
	_addOwnRules($_) for Slim::Player::Client::clients();
	Slim::Utils::Timers::setTimer(undef, time() + 60, \&_ownRulesForAll);
}

sub _clientEvent {
	my $request = shift;
	my $client = $request->client || return;
	# After the other plugins have reacted to the same event.
	Slim::Utils::Timers::setTimer($client, time() + 2, \&_addOwnRules);
}

sub _addOwnRules {
	my $client = shift || return;
	return unless $client->model eq APP_MODEL;
	my $id = lc($client->id);
	# The lossless format the phone chose: not tied to the switch below (the app decides).
	eval { _applyLossless($client) };
	$log->error("EasySqueezy: lossless format rules: $@") if $@;
	return unless $prefs->get('ownRules');

	my $table = Slim::Player::TranscodingHelper::Conversions();

	# C-3PO switched on for this phone (its default for every new player): its processing applies
	# to what it makes (lossless), so for the formats it handles only our MP3 rules stay, for
	# mobile data. C-3PO makes no MP3, and without them the phone would get no MP3 at all. A format
	# C-3PO doesn't handle (not ticked under its Input formats) gets our lossless rule too: its
	# general rules may be gone (C-3PO and SqueezeDSP replace them), which left it MP3 even on Wi-Fi.
	my $c3po = _c3poEnabledFor($client);
	my @lossless = grep { $_ ne 'mp3' } _phoneFormats($id);
	my $othersHandle = sub {
		my $in = shift;
		for my $out (@lossless) {
			for my $profile ("$in-$out-" . APP_MODEL . "-$id", "$in-$out-*-$id", "$in-$out-" . APP_MODEL . '-*', "$in-$out-*-*") {
				next unless exists $table->{$profile};
				next if $ownRules{$id} && $ownRules{$id}->{$profile};
				return 1 if Slim::Player::TranscodingHelper::checkBin($profile);
			}
		}
		return 0;
	};
	if ($c3po) {
		my @ours = grep { my ($in, $out) = split /-/, $_; $out ne 'mp3' && $othersHandle->($in) } keys %{ $ownRules{$id} || {} };
		for (@ours) {
			delete $ownRules{$id}->{$_};
			next unless exists $table->{$_};
			delete $Slim::Player::TranscodingHelper::commandTable{$_};
			delete $Slim::Player::TranscodingHelper::capabilities{$_};
		}
		$log->warn("EasySqueezy: C-3PO is switched on for $id, removed " . scalar(@ours) . " own lossless conversion rules for formats it handles (MP3 ones stay)") if @ours;
	}

	my ($stock, $dsd) = _rules();
	my @takeoverNames = _takeoverPlugins();
	my $takeover = scalar @takeoverNames;
	my @added;

	my $add = sub {
		my ($rule, $general) = @_;
		my ($in, $out, $caps, $command) = @$rule;
		return if $c3po && $out ne 'mp3' && $othersHandle->($in);
		my $profile = "$in-$out-" . APP_MODEL . "-$id";
		return if exists $table->{$profile};
		# The admin switched the general rule off in File Types: leave it off.
		return if $general && !Slim::Player::TranscodingHelper::enabledFormat("$in-$out-*-*");
		$Slim::Player::TranscodingHelper::commandTable{$profile} = $command;
		if (defined $caps) {
			Slim::Player::TranscodingHelper::_getCapabilities($profile, $caps);
		} else {
			$Slim::Player::TranscodingHelper::capabilities{$profile} = { I => 'noArgs', F => 'noArgs' };
		}
		push @added, $profile;
	};

	# Lyrion's stock rules, while a plugin has taken over the general ones.
	if ($takeover) {
		$add->($_, 1) for @$stock;
	}

	# DSD, when this phone has no usable rule for it.
	for my $rule (@$dsd) {
		my ($in, $out) = @$rule;
		# For MP3, also when the rules it has can't follow a bitrate limit (_canConvert).
		$add->($rule, 0) unless _canConvert($client, $in, $out);
	}

	if (@added) {
		$ownRules{$id}->{$_} = 1 for @added;
		$log->warn("EasySqueezy: added " . scalar(@added) . " conversion rules" . ($c3po ? ' (C-3PO on: MP3, and lossless for formats it doesn\'t handle)' : '') . " for $id" . ($takeover ? ' (' . join(', ', @takeoverNames) . ' enabled)' : ''));
	}
}

# The phone's chosen lossless format ('pcm' unless set), and what applies: 'pcm' while C-3PO is
# switched on for it (C-3PO processes its lossless playback and removes rules for it).
sub _losslessChoice {
	my $client = shift;
	my $chosen = $prefs->client($client)->get('lossless') || 'pcm';
	$chosen = 'pcm' unless grep { $_ eq $chosen } LOSSLESS_FORMATS;
	return ($chosen, _c3poEnabledFor($client) ? 'pcm' : $chosen);
}

my %losslessSets;    # choice => [[in, out, caps, command], ...]

sub _losslessSets {
	if (!%losslessSets) {
		my $data = Slim::Utils::PluginManager->dataForPlugin(__PACKAGE__);
		if ($data && $data->{basedir}) {
			for my $r (_parseRules(catfile($data->{basedir}, 'lossless-rules.conf'))) {
				push @{ $losslessSets{$r->[2]} }, [$r->[0], $r->[1], $r->[4], $r->[5]];
			}
		}
		$losslessSets{pcm} ||= [];
	}
	return \%losslessSets;
}

# Puts the phone's lossless format rules in Lyrion's table (again, after a restart or after
# another plugin removed them) and takes out those of a format no longer chosen.
sub _applyLossless {
	my $client = shift;
	my $id = lc($client->id);
	my (undef, $applies) = _losslessChoice($client);

	my %want;
	for my $rule (@{ _losslessSets()->{$applies} || [] }) {
		my ($in, $out, $caps, $command) = @$rule;
		$want{"$in-$out-" . APP_MODEL . "-$id"} = [$caps, $command];
	}

	my ($added, $removed) = (0, 0);
	for my $profile (keys %{ $losslessRules{$id} || {} }) {
		next if $want{$profile};
		delete $Slim::Player::TranscodingHelper::commandTable{$profile};
		delete $Slim::Player::TranscodingHelper::capabilities{$profile};
		$removed++;
	}
	for my $profile (keys %want) {
		my ($caps, $command) = @{ $want{$profile} };
		next if ($Slim::Player::TranscodingHelper::commandTable{$profile} // '') eq $command;
		$Slim::Player::TranscodingHelper::commandTable{$profile} = $command;
		Slim::Player::TranscodingHelper::_getCapabilities($profile, $caps);
		$added++;
	}
	$losslessRules{$id} = { map { $_ => 1 } keys %want };
	$log->warn("EasySqueezy: lossless format '$applies' for $id: $added rules added, $removed removed") if $added || $removed;
}

sub losslessCommand {
	my $request = shift;
	if ($request->isNotCommand([['easysqueezy'], ['lossless']])) {
		$request->setStatusBadDispatch();
		return;
	}
	my $client = $request->client;
	if (!$client || $client->model ne APP_MODEL) {
		$request->setStatusBadParams();
		return;
	}
	my $format = $request->getParam('format');
	if (defined $format && $format ne '') {
		if (!grep { $_ eq $format } LOSSLESS_FORMATS) {
			$request->setStatusBadParams();
			return;
		}
		$prefs->client($client)->set('lossless', $format);
		_applyLossless($client);
	}
	my ($chosen, $applies) = _losslessChoice($client);
	$request->addResult('format', $chosen);
	$request->addResult('applies', $applies);
	$request->addResult('c3po_on_player', _c3poEnabledFor($client) ? 1 : 0);
	# DSD to FLAC needs ffmpeg.
	$request->addResult('ffmpeg', Slim::Utils::Misc::findbin('ffmpeg') ? 1 : 0);
	$request->setStatusDone();
}

sub _c3poEnabledFor {
	my $client = shift;
	return 0 unless grep { /^Plugins::C3PO::/ } Slim::Utils::PluginManager->enabledPlugins;
	return preferences('plugin.C3PO')->client($client)->get('enable') ? 1 : 0;
}

# Rules this plugin added for a phone that are still in Lyrion's table.
sub _ownRuleCount {
	my $id = lc(shift || '');
	my $table = Slim::Player::TranscodingHelper::Conversions();
	return scalar grep { exists $table->{$_} } keys %{ $ownRules{$id} || {} };
}

# --- Conversion rules report (settings page) -------------------------------------------------

# With no phone connected, the page shows what a phone would get: Lyrion's rules plus those
# _addOwnRules would add when it connects (for a phone C-3PO isn't switched on for, with the
# default lossless format PCM). They're worked out here, never put in Lyrion's table:
# profile "in-out-easysqueezy-*" => { command, caps }.
our %preview;

sub _previewRules {
	my %p;
	return \%p unless $prefs->get('ownRules');
	my ($stock, $dsd) = _rules();
	my $table = Slim::Player::TranscodingHelper::Conversions();
	my $caps = \%Slim::Player::TranscodingHelper::capabilities;
	my $put = sub {
		my ($rule, $general) = @_;
		my ($in, $out, $capString, $command) = @$rule;
		my $profile = "$in-$out-" . APP_MODEL . '-*';
		return if exists $table->{$profile} || exists $p{$profile};
		return if $general && !Slim::Player::TranscodingHelper::enabledFormat("$in-$out-*-*");
		my $c = { I => 'noArgs', F => 'noArgs' };
		if (defined $capString && !exists $caps->{$profile}) {
			# Lyrion's own parser, on a profile that isn't in its table, then taken back out.
			Slim::Player::TranscodingHelper::_getCapabilities($profile, $capString);
			$c = delete $caps->{$profile} || $c;
		}
		$p{$profile} = { command => $command, caps => $c };
	};
	my @takeover = _takeoverPlugins();    # a list: sort in scalar context returns nothing
	if (@takeover) {
		$put->($_, 1) for @$stock;
	}
	for my $rule (@$dsd) {
		$put->($rule, 0) unless _canConvert(undef, $rule->[0], $rule->[1]);
	}
	return \%p;
}

# Lyrion's conversion table, with the previewed rules when there are any.
sub _table {
	my $table = Slim::Player::TranscodingHelper::Conversions();
	return $table unless %preview;
	return { %$table, map { $_ => $preview{$_}->{command} } keys %preview };
}

# Input formats in the order the page lists them; others follow alphabetically.
my @FORMAT_ORDER = qw(flc alc wav aif mp3 aac mp4 ogg ops wma wmal wmap ape mpc wvp dsf dff);

# Where a rule comes from: EASYSQUEEZY, C3PO, SQUEEZEDSP, STOCK (Lyrion's convert.conf),
# STOCKCOPY (the same, written for this player), PLAYER (another rule written for this player or model) or CUSTOM (custom-convert.conf,
# another plugin).
sub _ruleSource {
	my ($profile, $command) = @_;
	(my $base = $profile) =~ s/-\d+$//;
	my ($in, $out, $type, $id) = split /-/, $base;
	return 'EASYSQUEEZY' if $preview{$base};
	return 'EASYSQUEEZY' if $id ne '*' && (($ownRules{$id} && $ownRules{$id}->{$base}) || ($losslessRules{$id} && $losslessRules{$id}->{$base}));
	return 'C3PO' if $command =~ /C-?3PO/i;
	return 'SQUEEZEDSP' if $command =~ /SqueezeDSP/i;
	if ($id eq '*' && ($type eq '*' || $type eq 'transcode')) {
		my $stock = $stockCommand{"$in-$out-$type"};
		return 'STOCK' if defined $stock && $stock eq _norm($command);
		return 'CUSTOM';
	}
	# Written for this player: a copy of Lyrion's standard rule (C-3PO copies them for the players
	# it isn't on for), C-3PO's own, or someone else's.
	if ($id ne '*') {
		my $stock = $stockCommand{"$in-$out-*"};
		return 'STOCKCOPY' if defined $stock && $stock eq _norm($command);
		return 'C3PO' if grep { /^Plugins::C3PO::/ } Slim::Utils::PluginManager->enabledPlugins;
	}
	return 'PLAYER';
}

# Why Lyrion would pass over a rule: OFF (switched off in File Types), NOBIN (a program it
# needs isn't found), or '' when usable.
sub _ruleState {
	my $profile = shift;
	if (my $p = $preview{$profile}) {
		return _missingBins($p->{command}) ? 'NOBIN' : '';
	}
	return '' if Slim::Player::TranscodingHelper::checkBin($profile);
	return Slim::Player::TranscodingHelper::enabledFormat($profile) ? 'NOBIN' : 'OFF';
}

# The programs a rule's command names ([lame], [flac], ...) that aren't found, comma-separated.
sub _missingBins {
	my $command = shift // '';
	my %seen;
	return join(', ', grep { !$seen{$_}++ && !Slim::Utils::Misc::findbin($_) } $command =~ /\[([^\]]+)\]/g);
}

# The profiles Lyrion tries for $in, in its order (getConvertCommand2), for an EasySqueezy
# phone with id $id (or any one, without) that takes the app's formats.
# The formats a connected phone offered (its HELO: FLAC first with a lossless format other
# than PCM), or the app's usual list.
sub _phoneFormats {
	my $id = shift;
	if ($id && (my $client = Slim::Player::Client::getClient($id))) {
		my @formats = Slim::Player::CapabilitiesHelper::supportedFormats($client);
		return @formats if @formats;
	}
	return APP_OUTPUTS;
}

sub _profilesFor {
	my ($in, $id, $only) = @_;
	# $only: one output format (a download in that format), not the phone's whole list.
	my @formats = $only ? ($only) : _phoneFormats($id);
	if (preferences('server')->get('prioritizeNative')) {
		my @types = ($in);
		unshift @types, 'pcm' if $in =~ /wav/;
		for my $t (@types) {
			my ($f) = grep { /$t/ } @formats;
			@formats = ($f, grep { $_ !~ $t } @formats) if $f;
		}
	}
	my @profiles;
	for my $out (@formats) {
		push @profiles, ("$in-$out-" . APP_MODEL . "-$id", "$in-$out-*-$id") if $id;
		push @profiles, "$in-$out-" . APP_MODEL . '-*', "$in-$out-*-*";
		push @profiles, "$in-$out-transcode-*"
			if $in eq $out && Slim::Player::TranscodingHelper::enabledFormat("$in-$out-*-*");
	}
	return @profiles;
}

# The rule Lyrion would pick for $in, as getConvertCommand2 does. $limit: a bitrate limit is
# set (mobile data), so rules that can lower the bitrate (B) win over those that can't.
sub _pickRule {
	# $only: see _profilesFor; $fileOnly: the rule must read a file (F) or its contents (I),
	# not a remote URL only (a download of a song file).
	my ($in, $id, $limit, $only, $fileOnly) = @_;
	my $table = _table();
	my $caps  = \%Slim::Player::TranscodingHelper::capabilities;
	my (@skipped, $backup);

	PROFILE: for my $base (_profilesFor($in, $id, $only)) {
		for (my $instance = 0; ; $instance++) {
			my $profile = $instance ? "$base-$instance" : $base;
			next PROFILE unless exists $table->{$profile};
			if (my $state = _ruleState($profile)) {
				push @skipped, { profile => $profile, state => $state, source => _ruleSource($profile, $table->{$profile}), missing => _missingBins($table->{$profile}) };
				next PROFILE;
			}
			my $c = $caps->{$profile} || ($preview{$profile} && $preview{$profile}->{caps}) || {};
			next unless $c->{I} || $c->{F} || (!$fileOnly && $c->{R});
			my $rule = { profile => $profile, command => $table->{$profile}, source => _ruleSource($profile, $table->{$profile}), out => (split /-/, $profile)[1] };
			if ($limit && !$c->{B}) {
				$backup ||= $rule;
				next;
			}
			return { %$rule, skipped => \@skipped };
		}
	}
	return { %$backup, skipped => \@skipped } if $backup;
	return { none => 1, skipped => \@skipped };
}

sub _formatName {
	my $in = shift;
	my $key = uc $in;
	return Slim::Utils::Strings::stringExists($key) ? Slim::Utils::Strings::string($key) : $in;
}

# For the settings page: per connected EasySqueezy phone (or, with none, any EasySqueezy
# phone), the rule Lyrion uses for each input format on Wi-Fi and with a bitrate limit, and all
# rules that apply to it in Lyrion's lookup order.
sub ruleReport {
	my ($stock) = _rules();
	my @takeoverNames = _takeoverPlugins();
	my @phones = sort { lc($a->name) cmp lc($b->name) } grep { $_->model eq APP_MODEL } Slim::Player::Client::clients();
	my @targets = @phones ? map { { name => $_->name, id => lc($_->id), client => $_ } } @phones : ({ name => '', id => '' });

	my %rank;
	@rank{@FORMAT_ORDER} = (0 .. $#FORMAT_ORDER);

	my @report;
	for my $t (@targets) {
		my $id = $t->{id};
		# No phone connected: include the rules the plugin adds for one when it connects.
		local %preview = $id ? () : %{ _previewRules() };
		my $table = _table();
		# The input formats that have any rule for this phone, and those Lyrion's standard rules
		# cover: a plugin that took over the general rules may have left a format with none.
		my %inputs = map { $_->[0] => 1 } @$stock;
		for my $profile (keys %$table) {
			my ($in, $out, $type, $pid) = split /-/, $profile;
			next unless _appOutput($out);
			next unless $type eq '*' || $type eq APP_MODEL || $type eq 'transcode';
			next unless $pid eq '*' || ($id && $pid eq $id);
			$inputs{$in} = 1;
		}
		my @inputs = sort { ($rank{$a} // 99) <=> ($rank{$b} // 99) || $a cmp $b } keys %inputs;

		my (@rows, @all);
		for my $in (@inputs) {
			push @rows, {
				format   => $in,
				name     => _formatName($in),
				wifi     => _pickRule($in, $id, 0),
				limited  => _pickRule($in, $id, 1),
			};
			for my $base (_profilesFor($in, $id)) {
				for (my $instance = 0; ; $instance++) {
					my $profile = $instance ? "$base-$instance" : $base;
					last unless exists $table->{$profile};
					push @all, {
						profile => $profile,
						command => $table->{$profile},
						source  => _ruleSource($profile, $table->{$profile}),
						state   => _ruleState($profile),
						missing => _missingBins($table->{$profile}),
					};
				}
			}
		}

		# Summary: formats without MP3 for mobile data, and formats that can't play at all,
		# grouped by the programs whose absence is the reason.
		my (%noMobile, %cantPlay);
		# The programs missing for every rule passed over (the common blocker: for Musepack
		# mppdec, not also lame which only its MP3 rule needs).
		my $missingOf = sub {
			my @sets = map { { map { $_ => 1 } split /,\s*/, $_->{missing} } } grep { $_->{missing} } @{ shift->{skipped} || [] };
			return '' unless @sets;
			my @common = grep { my $p = $_; !grep { !$_->{$p} } @sets } keys %{ $sets[0] };
			return join(', ', sort @common);
		};
		# A format with no rule at all (none passed over) lost Lyrion's standard ones: "\0", shown
		# as taken over by the plugins that replace them.
		my $reason = sub {
			my $r = shift;
			return $missingOf->($r) if @{ $r->{skipped} || [] } || !$r->{none};
			return @takeoverNames ? "\0" : '';
		};
		for my $row (@rows) {
			if ($row->{wifi}->{none}) {
				push @{ $cantPlay{ $reason->($row->{wifi}) } }, $row->{name};
			} elsif ($row->{limited}->{none} || ($row->{limited}->{out} // '') eq 'pcm') {
				push @{ $noMobile{ $reason->($row->{limited}) } }, $row->{name};
			}
		}
		my $groups = sub {
			my $h = shift;
			[ map { { missing => ($_ eq "\0" ? '' : $_), taken => ($_ eq "\0" ? 1 : 0), names => join(', ', @{ $h->{$_} }) } } sort keys %$h ];
		};

		push @report, {
			cant_play => $groups->(\%cantPlay),
			no_mobile => $groups->(\%noMobile),
			formats  => scalar @rows,
			name     => $t->{name},
			id       => $id,
			c3po     => $t->{client} ? _c3poEnabledFor($t->{client}) : 0,
			lossless => $t->{client} ? [ _losslessChoice($t->{client}) ] : [],
			own      => $id ? _ownRuleCount($id) : scalar(keys %preview),
			takeover => join(', ', @takeoverNames),
			rows     => \@rows,
			all      => \@all,
		};
	}
	return \@report;
}

sub capabilitiesQuery {
	my $request = shift;

	if ($request->isNotQuery([['easysqueezy'], ['capabilities']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client = $request->client;

	# The app asks when it connects: make sure this phone's own rules are in place first.
	_addOwnRules($client) if $client;

	# The programs conversions use.
	$request->addResult('lame', _hasBin('lame'));
	$request->addResult('ffmpeg', _hasBin('ffmpeg'));
	$request->addResult('flac', _hasBin('flac'));
	$request->addResult('sox', _hasBin('sox'));

	# What this player (or, without one, any EasySqueezy player) can get.
	$request->addResult('flac_mp3', _canConvert($client, 'flc', 'mp3'));
	$request->addResult('flac_pcm', _canConvert($client, 'flc', 'pcm'));
	$request->addResult('dsd_mp3', _canConvert($client, 'dsf', 'mp3'));
	$request->addResult('dsd_pcm', _canConvert($client, 'dsf', 'pcm'));
	# Lyrion's song downloads (/music/<id>/download.mp3) use only the general rules.
	$request->addResult('flac_mp3_download', _canConvert($client, 'flc', 'mp3', 1));

	# Plugins that replace Lyrion's general conversion rules for the formats they handle with
	# rules for single players (seen with C-3PO and SqueezeDSP): other players, and song
	# downloads, then get no conversion for those formats.
	my @takeover = _takeoverPlugins();
	$request->addResult('c3po', (grep { $_ eq 'C-3PO' } @takeover) ? 1 : 0);
	$request->addResult('takeover', join(',', @takeover));

	# The app's own rules (0.4): switched on, and how many are in use for this phone.
	$request->addResult('own_rules_enabled', $prefs->get('ownRules') ? 1 : 0);
	$request->addResult('pause_stays', $prefs->get('pauseStays') ? 1 : 0);
	if ($client) {
		my (undef, $applies) = _losslessChoice($client);
		$request->addResult('lossless', $applies);
	}
	$request->addResult('own_rules', $client ? _ownRuleCount($client->id) + 0 : 0);
	$request->addResult('c3po_on_player', $client ? _c3poEnabledFor($client) : 0);

	$request->addResult('player', $client ? $client->id : '');
	$request->setStatusDone();
}

sub serverLogQuery {
	my $request = shift;

	if ($request->isNotQuery([['easysqueezy'], ['serverlog']])) {
		$request->setStatusBadDispatch();
		return;
	}

	if (!$prefs->get('shareLog')) {
		$request->addResult('disabled', 1);
		$request->setStatusDone();
		return;
	}

	my $from = $request->getParam('from') || 0;
	my $to   = $request->getParam('to') || time() + 60;
	my $client = $request->client;
	my $me = $client ? lc($client->id) : '';

	my $file = Slim::Utils::Log::serverLogFile();
	my $fh;
	if (!$file || !open($fh, '<', $file)) {
		$request->addResult('error', 'no server log file');
		$request->setStatusDone();
		return;
	}

	my $size  = -s $fh;
	my $start = $size > LOG_TAIL_BYTES ? $size - LOG_TAIL_BYTES : 0;
	if ($start) {
		seek($fh, $start, 0);
		<$fh>;    # the rest of a cut line
	}

	my @out;
	my $keep = 0;
	while (my $line = <$fh>) {
		# Entries start with [yy-mm-dd hh:mm:ss.ffff] in the server's local time; lines without
		# it (continuations) follow their entry.
		if ($line =~ /^\[(\d\d)-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)/) {
			my $t = mktime($6, $5, $4, $3, $2 - 1, $1 + 100);
			$keep = defined $t && $t >= $from && $t <= $to;
			if ($keep) {
				# Not lines about other players.
				for my $mac ($line =~ /\b([0-9a-f]{2}(?::[0-9a-f]{2}){5})\b/gi) {
					if (lc($mac) ne $me) { $keep = 0; last }
				}
			}
		}
		push @out, $line if $keep;
	}
	close($fh);

	my $text = join('', @out);
	my $truncated = 0;
	if (length($text) > LOG_MAX_BYTES) {
		$text = substr($text, -LOG_MAX_BYTES());
		$text =~ s/^[^\n]*\n//;
		$truncated = 1;
	}

	$request->addResult('log', $text);
	$request->addResult('lines', scalar @out);
	$request->addResult('truncated', $truncated);
	# 1: the log file was read from its start (older lines than these don't exist any more).
	$request->addResult('whole_file', $start ? 0 : 1);
	$request->setStatusDone();
}

1;
