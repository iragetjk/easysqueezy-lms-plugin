package Plugins::EasySqueezy::QueueEnd;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# Why playback stopped (plugin item 11): Lyrion only says "playlist stop". When an EasySqueezy
# phone stops, this looks at the queue and at what should have added more songs (Don't Stop The
# Music, a dynamic playlist or Random Play, which tell Don't Stop The Music to stay out), and
# writes one plain line to server.log with the player's MAC (so it is in the phone's shared
# log), and keeps it for `easysqueezy queueend`.

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant APP_MODEL => 'easysqueezy';
# A stop/power/mode command this close to the stop: someone stopped it (not the end of a queue).
use constant COMMAND_WINDOW => 3;
# The check runs this long after the stop, once the command that caused it has been notified.
use constant SETTLE => 1;
use constant KEEP => 5;

my $log = logger('plugin.easysqueezy');

# client id => { cmd => time, newsong => time, added => [time, source], cantopen => [time, url, error], reports => [...] }
my %state;
# Events in order (several in one second): an addition counts only after the last song change.
my $seq = 0;

sub init {
	Slim::Control::Request::subscribe(\&_event, [['playlist', 'stop', 'power', 'mode', 'pause']]);
}

sub _ours {
	my $client = shift;
	return $client && $client->model eq APP_MODEL;
}

sub _event {
	my $request = shift;
	my $client  = $request->client or return;
	$client = $client->master;
	return unless _ours($client);

	my $s = $state{$client->id} ||= {};
	my $now = time();

	if ($request->isCommand([['stop']]) || $request->isCommand([['power']]) || $request->isCommand([['mode'], ['stop']])) {
		$s->{cmd} = $now;
		return;
	}
	return unless $request->isCommand([['playlist']]);

	my $sub = $request->getRequest(1) || '';
	if ($sub eq 'newsong') {
		$s->{newsong} = ++$seq;
		delete $s->{cantopen};
	}
	elsif ($sub =~ /^(?:add|addtracks|insert|inserttracks)$/) {
		# (load/play replace the queue: not songs added to it.)
		my $source = $request->source || '';
		$source =~ s/^(?:Slim::Plugin|Plugins)::(\w+).*/$1/;
		$s->{added} = [++$seq, $source || 'a controller'];
	}
	elsif ($sub eq 'cant_open') {
		$s->{cantopen} = [$now, $request->getParam('_url') || '', $request->getParam('_error') || ''];
	}
	elsif ($sub eq 'stop') {
		Slim::Utils::Timers::killTimers($client, \&_check);
		Slim::Utils::Timers::setTimer($client, $now + SETTLE, \&_check, $now);
	}
}

sub _check {
	my ($client, $stoppedAt) = @_;
	# Playing (or paused) again: a stop on the way to something new, such as a playlist or album
	# loaded (Lyrion stops the player, then starts the new queue), not a stop to explain.
	my $mode = eval { Slim::Player::Source::playmode($client) } // '';
	return if $mode && $mode ne 'stop';
	my $s = $state{$client->id} ||= {};
	my $r = eval { _reason($client, $s, $stoppedAt) };
	if ($@) {
		$log->error("EasySqueezy: why playback stopped: $@");
		return;
	}
	return unless $r;

	$r->{time} = $stoppedAt;
	my $reports = $s->{reports} ||= [];
	unshift @$reports, $r;
	splice @$reports, KEEP if @$reports > KEEP;

	# The MAC makes the line part of this phone's shared diagnostics log (see serverLogQuery).
	my $line = sprintf('EasySqueezy: %s (%s) stopped %s: %s',
		$client->name, $client->id, $r->{where}, $r->{text});
	$r->{level} eq 'warn' ? $log->warn($line) : $log->info($line);
}

# What happened, as { code, text, where, level }; undef when there's nothing to say.
sub _reason {
	my ($client, $s, $stoppedAt) = @_;

	my $count  = Slim::Player::Playlist::count($client);
	my $index  = Slim::Player::Source::playingSongIndex($client) // 0;
	my $repeat = Slim::Player::Playlist::repeat($client);
	my $where  = $count ? sprintf('at song %d of %d', $index + 1, $count) : 'with an empty queue';
	my %r = (where => $where, index => $index, count => $count, level => 'warn');

	if ($s->{cmd} && abs($s->{cmd} - $stoppedAt) <= COMMAND_WINDOW) {
		return { %r, code => 'command', level => 'info', text => 'stopped by a command (the app, another controller, or a power off)' };
	}
	if (!$count) {
		return { %r, code => 'cleared', text => 'the queue was cleared' };
	}

	if ($index < $count - 1 && !$repeat) {
		if (my $c = $s->{cantopen}) {
			return { %r, code => 'cant_open', text => "the next song couldn't be opened ($c->[2]: $c->[1]), with songs still in the queue" };
		}
		return { %r, code => 'songs_left', text => 'songs are still in the queue, but the server sent no next one' };
	}
	if ($repeat) {
		return { %r, code => 'repeat', text => 'repeat is on, but the server sent no next song' . (_cantOpen($s)) };
	}

	# The end of the queue, repeat off: who should have added more?
	my $added = '';
	if ($s->{added} && $s->{newsong} && $s->{added}[0] > $s->{newsong}) {
		$added = " (songs were added by $s->{added}[1] during the last song)";
	}

	if (my $other = _conflictingActive($client)) {
		return { %r, code => 'dynamic_empty', text => "the queue ran out: $other is active for this player and added no more songs$added" };
	}

	my $dstmClass = 'Slim::Plugin::DontStopTheMusic::Plugin';
	my $provider = eval { preferences('plugin.dontstopthemusic')->client($client)->get('provider') } || '';
	if (!$provider || !Slim::Utils::PluginManager->isEnabled($dstmClass)) {
		my $note = $provider ? " (Don't Stop The Music is set for it, but its plugin is disabled)" : '';
		return { %r, code => 'end', level => 'info', text => "the queue ended: repeat is off and nothing adds songs for this player$note" };
	}

	my $mix = _mixName($client, $provider);
	if (!eval { $dstmClass->getHandler($client) }) {
		return { %r, code => 'dstm_unavailable', text => "Don't Stop The Music is set to \"$mix\", which isn't available (its plugin is disabled or gone)" };
	}
	if (_lastIsStream($client)) {
		return { %r, code => 'dstm_stream_last', text => "Don't Stop The Music doesn't start a mix after a radio station or stream (the last item in the queue)" };
	}
	if (eval { $client->_pluginData->{DontStopTheMusic}{active} }) {
		return { %r, code => 'dstm_waiting', text => "Don't Stop The Music asked \"$mix\" for songs and it hasn't answered (a slow or failing music service?)" };
	}
	my $random = Slim::Utils::PluginManager->isEnabled('Slim::Plugin::RandomPlay::Plugin') ? '' : ', and Random Mix, its fallback, is disabled';
	return { %r, code => 'dstm_empty', text => "Don't Stop The Music (\"$mix\") found no songs to add$random$added" };
}

sub _cantOpen {
	my $s = shift;
	my $c = $s->{cantopen} or return '';
	return " (couldn't open $c->[1]: $c->[2])";
}

# A plugin that adds songs itself and tells Don't Stop The Music to stay out (Random Play,
# Dynamic Playlists...), if one is active for this player: its name.
sub _conflictingActive {
	my $client = shift;
	for my $plugin (Slim::Utils::PluginManager->enabledPlugins) {
		my $data = Slim::Utils::PluginManager->dataForPlugin($plugin) || {};
		next unless $data->{canConflictWithDSTM};
		next unless eval { $plugin->disableDSTM($client) };
		my $name = eval { Slim::Utils::Strings::getString($data->{name}) } || $data->{name} || $plugin;
		return $name;
	}
	return '';
}

sub _mixName {
	my ($client, $provider) = @_;
	my $name = eval { Slim::Plugin::DontStopTheMusic::Plugin::getString($provider, $client) };
	$name = eval { Slim::Utils::Strings::getString($provider) } if !$name || $name eq $provider;
	return $name || $provider;
}

sub _lastIsStream {
	my $client = shift;
	my $last = Slim::Player::Playlist::playList($client)->[-1] or return 0;
	my (undef, undef, $duration) = eval { Slim::Plugin::DontStopTheMusic::Plugin->getMixablePropertiesFromTrack($client, $last) };
	return !$duration;
}

# For `easysqueezy queueend`: this player's latest reports, newest first.
sub reports {
	my $client = shift or return [];
	return ($state{$client->master->id} || {})->{reports} || [];
}

1;
