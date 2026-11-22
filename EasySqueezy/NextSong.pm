package Plugins::EasySqueezy::NextSong;

# Copyright (C) 2026 Eradj Tursun-Zade (irage) <irage@irage.org>
# SPDX-License-Identifier: GPL-2.0-only
# This program is free software; you can redistribute it and/or modify it under the terms of
# the GNU General Public License version 2 (see LICENSE).

# Restart only the queued next song (plugin item 8, the app's scenario 23).
#
# While a song plays, Lyrion already streams the next one to the phone. When that stream
# breaks (no data, the connection stays up), the app can fetch a file again as a download,
# but not a song that isn't a file (TIDAL, Qobuz, radio...); then it could only ask for it
# when it should start, a short gap. `easysqueezy restartnext` has Lyrion open the next song
# again and send it as a new stream now, without touching the one playing: the same thing
# Lyrion does when it moves on to the next song (StreamingController::_Stream with that song,
# which is already second in its song queue, so nothing is added twice).

use strict;

use Slim::Utils::Log;

use constant APP_MODEL => 'easysqueezy';

my $log = logger('plugin.easysqueezy');

sub init {
	# easysqueezy restartnext  (for the player given)  ->  restarted 1, index; or restarted 0, error
	Slim::Control::Request::addDispatch(['easysqueezy', 'restartnext'], [1, 0, 0, \&restartNextCommand]);
}

sub restartNextCommand {
	my $request = shift;
	if ($request->isNotCommand([['easysqueezy'], ['restartnext']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $client = $request->client;
	my ($ok, $result) = eval { _restartNext($client) };
	($ok, $result) = (0, "failed: $@") if $@;

	$request->addResult('restarted', $ok ? 1 : 0);
	if ($ok) {
		$request->addResult('index', $result);
	} else {
		$request->addResult('error', $result);
	}
	$log->warn(sprintf('EasySqueezy: %s (%s) asked to stream the next song again: %s',
		$client->name, $client->id, $ok ? 'streaming song ' . ($result + 1) . ' again' : "not done: $result"));
	$request->setStatusDone();
}

# (1, the song's queue index) or (0, why not).
sub _restartNext {
	my $client = shift;
	return (0, 'not an EasySqueezy phone') unless $client->model eq APP_MODEL;

	my $controller = $client->controller;
	return (0, 'synced with other players') if scalar($controller->activePlayers) > 1;
	return (0, 'not playing') unless $controller->isPlaying(1);

	my $playing = $controller->playingSong;
	my $next    = $controller->streamingSong;
	return (0, 'no next song is being streamed') unless $playing && $next && $playing != $next;

	$next->resetSeekdata if $next->can('resetSeekdata');
	Slim::Player::StreamingController::_Stream($controller, undef, { song => $next });
	return (1, $next->index);
}

1;
