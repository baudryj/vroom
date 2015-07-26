#!/usr/bin/env perl

# This file is part of the VROOM project
# Released under the MIT licence
# Copyright 2014-2015 Daniel Berteaud <daniel@firewall-services.com>

use lib 'lib';
use Mojolicious::Lite;
use Mojolicious::Plugin::Mail;
use Mojolicious::Plugin::Database;
use Mojolicious::Plugin::StaticCompressor;
use Vroom::Constants;
use Vroom::Conf;
use Crypt::SaltedHash;
use Digest::HMAC_SHA1 qw(hmac_sha1);
use MIME::Base64;
use File::stat;
use File::Basename;
use Session::Token;
use Email::Valid;
use Protocol::SocketIO::Handshake;
use Protocol::SocketIO::Message;
use File::Path qw(make_path);
use File::Basename;
use DateTime;
use Array::Diff;
use Data::Dumper;

app->log->level('info');

our $config = Vroom::Conf::get_conf();

# Try to create the directories we need
foreach my $dir (qw/assets/){
  if (!-d $config->{'directories.cache'} . '/' . $dir){
    make_path($config->{'directories.cache'} . '/' . $dir, { mode => 0770 });
  }
  elsif (!-w $config->{'directories.cache'} . '/' . $dir){
    die $config->{'directories.cache'} . '/' . "$dir is not writable";
  }
}

# Optional features
our $optf = {};

# Create etherpad api client if enabled
if ($config->{'etherpad.uri'} =~ m/https?:\/\/.*/ && $config->{'etherpad.api_key'} ne ''){
  my $etherpad = eval { require Etherpad };
  if ($etherpad){
    import Etherpad;
    $optf->{etherpad} = Etherpad->new({
      url => $config->{'etherpad.uri'},
      apikey => $config->{'etherpad.api_key'}
    });
    if (!$optf->{etherpad}->check_token){
      app->log->info("Can't connect to Etherpad-Lite API, check your API key and uri");
      $optf->{etherpad} = undef;
    }
  }
  else{
    app->log->info("Etherpad perl module not found, disabling Etherpad-Lite support");
  }
}

# Check if Excel export is available
my $excel = eval {
  require File::Temp;
  require Excel::Writer::XLSX;
  require Mojolicious::Plugin::RenderFile;
};
if ($excel){
  import File::Temp;
  import Excel::Writer::XLSX;
  import Mojolicious::Plugin::RenderFile;
  $optf->{excel} = 1;
}

# Global error check
our $error = undef;

# Global peers hash
our $peers = {};

# Initialize localization
plugin I18N => {
  namespace => 'Vroom::I18N',
};

# Connect to the database
# Only MySQL supported for now
plugin database => {
  dsn      => $config->{'database.dsn'},
  username => $config->{'database.user'},
  password => $config->{'database.password'},
  options  => {
    mysql_enable_utf8    => 1,
    mysql_auto_reconnect => 1,
    RaiseError           => 1,
    PrintError           => 0
  }
};

# Load mail plugin with its default values
plugin mail => {
  from => $config->{'email.from'},
  type => 'text/html',
};

# Static resources compressor
plugin StaticCompressor => {
  url_path_prefix    => 'assets',
  file_cache_path    => $config->{'directories.cache'} . '/assets/',
  disable_on_devmode => 1
};

# Stream files
plugin 'RenderFile';

##########################
#  Validation helpers    #
##########################

# Take a string as argument and check if it's a valid room name
helper valid_room_name => sub {
  my $self = shift;
  my $name = shift;
  my $ret  = {};
  # A few names are reserved
  my @reserved = qw(about help feedback feedback_thanks goodbye admin locales api
                    missing dies kicked invitation js css img fonts snd documentation);
  if (!$name || $name !~ m/^[\w\-]{1,49}$/ || grep { $name eq $_ } @reserved){
    return 0;
  }
  return 1;
};

# Check arg is a valid ID number
helper valid_id => sub {
  my $self = shift;
  my $id   = shift;
  if (!$id || $id !~ m/^\d+$/){
    return 0;
  }
  return 1;
};

# Check email address format
helper valid_email => sub {
  my $self  = shift;
  my $email = shift;
  return Email::Valid->address($email);
};

# Validate a date in YYYY-MM-DD format
# Also accepts YYYY-MM-DD hh:mm:ss
helper valid_date => sub {
  my $self = shift;
  my $date = shift;
  if ($date !~ m/^\d{4}\-\d{1,2}\-\d{1,2}(\s+\d{1,2}:\d{1,2}:\d{1,2})?$/){
    $self->app->log->debug("$date is not a valid date");
    return 0;
  }
  return 1;
};

##########################
#   Various helpers      #
##########################

# Check if the database schema is the one we expect
helper check_db_version => sub {
  my $self = shift;
  my $sth = eval {
    $self->db->prepare('SELECT `value`
                          FROM `config`
                          WHERE `key`=\'schema_version\'');
  };
  $sth->execute;
  my $ver = undef;
  $sth->bind_columns(\$ver);
  $sth->fetch;
  return ($ver eq Vroom::Constants::DB_VERSION) ? '1' : '0';
};

# Get optional features
helper get_opt_features => sub {
  my $self = shift;
  return $optf;
};

# Log an event
helper log_event => sub {
  my $self  = shift;
  my $event = shift;
  if (!$event->{event} || !$event->{msg}){
    $self->app->log->debug("Oops, invalid event received");
    return 0;
  }
  my $addr = $self->tx->remote_address || '127.0.0.1';
  my $user = $self->get_name || 'VROOM daemon';
  my $sth = eval {
    $self->db->prepare('INSERT INTO `audit` (`date`,`event`,`from_ip`,`user`,`message`)
                          VALUES (CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'),?,?,?,?)');
  };
  $sth->execute(
    $event->{event},
    $addr,
    $user,
    $event->{msg}
  );
  $self->app->log->info('[' . $addr . '] [' . $user . '] [' . $event->{event} . '] ' . $event->{msg});
  return 1;
};

# Return a list of event between 2 dates
helper get_event_list => sub {
  my $self  = shift;
  my $start = shift;
  my $end   = shift;
  # Check both start and end dates seems valid
  if (!$self->valid_date($start) || !$self->valid_date($end)){
    $self->app->log->debug("Invalid date submitted while looking for events");
    return 0;
  }
  my $sth;
  $sth = eval {
    $self->db->prepare('SELECT * FROM `audit`
                          WHERE `date`>=?
                            AND `date`<=?');
  };
  # We want both dates to be inclusive, as the default time is 00:00:00
  # if not given, append 23:59:59 to the end date
  $end .= ' 23:59:59' if ($end !~ /\s+\d{1,2}:\d{1,2}:\d{1,2}$/);
  $sth->execute($start, $end);
  # Everything went fine, return the list of event as a hashref
  return $sth->fetchall_hashref('id');
};

# Generate and manage rotation of session keys
# used to sign cookies
helper update_session_keys => sub {
  my $self = shift;
  # First, delete obsolete session keys
  my $sth = eval {
    $self->db->prepare('DELETE FROM `session_keys`
                          WHERE `date` < DATE_SUB(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'), INTERVAL 72 HOUR)');
  };
  $sth->execute;
  # Now, retrieve all remaining keys, to check if we have enough of them
  $sth = eval {
    $self->db->prepare('SELECT `key` FROM `session_keys`
                         ORDER BY `date` DESC');
  };
  $sth->execute;
  my $keys = $sth->fetchall_hashref('key');
  my @keys = keys %$keys;
  # Now, check how many keys are less than 24 hours old
  $sth = eval {
    $self->db->prepare('SELECT COUNT(`key`) FROM `session_keys`
                         WHERE `date` > DATE_SUB(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'), INTERVAL 24 HOUR)');
  };
  $sth->execute;
  my $recent_keys = $sth->fetchrow;
  if ($recent_keys < 1){
    $self->app->log->debug("Generating a new key to sign session cookies");
    my $new_key = Session::Token->new(
       alphabet => ['a'..'z', 'A'..'Z', '0'..'9', '.:;,/!%$#~{([-_)]}=+*|'],
       entropy  => 512
    )->get;
    unshift @keys, $new_key;
    $sth = eval {
      $self->db->prepare('INSERT INTO `session_keys` (`key`,`date`)
                           VALUES (?,CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'))');
    };
    $sth->execute($new_key);
  }
  $self->app->secrets(\@keys);
  return 1;
};

# Return human readable username if it exists, or just the session ID
helper get_name => sub {
  my $self = shift;
  if ($ENV{'REMOTE_USER'} && $ENV{'REMOTE_USER'} ne ''){
    return $ENV{'REMOTE_USER'};
  }
  return $self->session('id');
};

# Create a cookie based session
# And a new API key
helper login => sub {
  my $self = shift;
  if ($self->session('id') && $self->session('id') ne ''){
    return 1;
  }
  my $id  = $self->get_random(256);
  my $key = $self->get_random(256);
  my $sth = eval {
    $self->db->prepare('INSERT INTO `api_keys`
                         (`token`,`not_after`)
                         VALUES (?,DATE_ADD(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'), INTERVAL 24 HOUR))');
  };
  $sth->execute($key);
  $self->session(
    id  => $id,
    key => $key
  );
  $self->log_event({
    event => 'session_create',
    msg   => 'User logged in'
  });
  return 1;
};

# Force the session cookie to expire on logout
helper logout => sub {
  my $self = shift;
  my $room = shift;
  # Logout from etherpad
  if ($optf->{etherpad} && $self->session($room) && $self->session($room)->{etherpadSessionId}){
    $optf->{etherpad}->delete_session($self->session($room)->{etherpadSessionId});
  }
  if ($self->session('peer_id') && 
      $peers->{$self->session('peer_id')} &&
      $peers->{$self->session('peer_id')}->{socket}){
    $peers->{$self->session('peer_id')}->{socket}->finish;
  }
  my $sth = eval {
    $self->db->prepare('DELETE FROM `api_keys`
                         WHERE `token`=?');
  };
  $sth->execute($self->session('key'));
  $self->session( expires => 1 );
  $self->log_event({
    event => 'session_destroy',
    msg   => 'User logged out'
  });
  return 1;
};

# Create a new room in the DB
# Requires one arg: the name of the room
helper create_room => sub {
  my $self = shift;
  my $name = shift;
  # Convert room names to lowercase
  if ($name ne lc $name){
    $name = lc $name;
  }
  # Check if the name is valid
  if (!$self->valid_room_name($name)){
    return 0;
  }
  # Fail if the room already exists
  if ($self->get_room_by_name($name)){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('INSERT INTO `rooms`
                          (`name`,
                           `create_date`,
                           `last_activity`)
                          VALUES (?,
                                  CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'),
                                  CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\')
                                 )');
  };
  $sth->execute($name);
  $self->log_event({
    event => 'room_create',
    msg   => "Room $name created"
  });
  # Create a pad if enabled
  if ($optf->{etherpad}){
    $self->create_pad($name);
  }
  return 1;
};

# Takse a string as argument
# Return a room object if a room with that name is found
# Else return undef
helper get_room_by_name => sub {
  my $self = shift;
  my $name = shift;
  if (!$self->valid_room_name($name)){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `rooms`
                          WHERE `name`=?');
  };
  $sth->execute($name);
  return $sth->fetchall_hashref('name')->{$name}
};

# Same as get_room_by_name, but take a room ID as argument
helper get_room_by_id => sub {
  my $self = shift;
  my $id   = shift;
  if (!$self->valid_id($id)){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `rooms`
                          WHERE `id`=?');
  };
  $sth->execute($id);
  return $sth->fetchall_hashref('id')->{$id};
};

# Update a room, take a room object as argument (hashref)
helper modify_room => sub {
  my $self = shift;
  my $room = shift;
  if (!$self->valid_id($room->{id}) || !$self->valid_room_name($room->{name})){
    return 0;
  }
  my $old_room = $self->get_room_by_id($room->{id});
  if (!$old_room){
    return 0;
  }
  if (!$room->{max_members} ||
      ($room->{max_members} > $config->{'rooms.max_members'} && $config->{'rooms.max_members'} > 0)){
    $room->{max_members} = 0;
  }
  if (($room->{locked}       && $room->{locked}       !~ m/^0|1$/) ||
      ($room->{ask_for_name} && $room->{ask_for_name} !~ m/^0|1$/) ||
      ($room->{persistent}   && $room->{persistent}   !~ m/^0|1$/) ||
       $room->{max_members}  !~ m/^\d+$/){
    return 0;
  }
  # Merge old and new params
  $room = { %$old_room, %$room };
  my $sth = eval {
    $self->db->prepare('UPDATE `rooms`
                          SET `locked`=?,
                              `ask_for_name`=?,
                              `join_password`=?,
                              `owner_password`=?,
                              `persistent`=?,
                              `max_members`=?
                          WHERE `id`=?');
  };
  $sth->execute(
    $room->{locked},
    $room->{ask_for_name},
    $room->{join_password},
    $room->{owner_password},
    $room->{persistent},
    $room->{max_members},
    $room->{id}
  );
  my $msg = "Room " . $room->{name} ." modified";
  my $mods = '';
  # Now, log which fields have been modified
  foreach my $field (keys %$room){
    if (($old_room->{$field} // '' ) ne ($room->{$field} // '')){
      # Just hide passwords
      if ($field =~ m/_password$/){
        $old_room->{$field} = ($old_room->{$field}) ? '<hidden>' : '<unset>';
        $room->{$field}     = ($room->{$field})     ? '<hidden>' : '<unset>';
      }
      $mods .= $field . ": " . $old_room->{$field} . ' -> ' . $room->{$field} . "\n";
    }
  }
  if ($mods ne ''){
    chomp($mods);
    $msg .= "\nModified fields:\n$mods";
    $self->log_event({
      event => 'room_modify',
      msg   => $msg
    });
  }
  return 1;
};

# Set the role of a peer
helper set_peer_role => sub {
  my $self = shift;
  my $data = shift;
  # Check the peer exists and is already in the room
  if (!$data->{peer_id} ||
      !$peers->{$data->{peer_id}}){
    return 0;
  }
  $peers->{$data->{peer_id}}->{role} = $data->{role};
  $self->log_event({
    event => 'peer_role',
    msg   => "Peer " . $data->{peer_id} . " has now the " .
             $data->{role} . " role in room " . $peers->{$data->{peer_id}}->{room}
  });
  return 1;
};

# Return the role of a peer, take a peer object as arg ($data = { peer_id => XYZ })
helper get_peer_role => sub {
  my $self    = shift;
  my $peer_id = shift;
  return $peers->{$peer_id}->{role};
};

# Promote a peer to owner
helper promote_peer => sub {
  my $self    = shift;
  my $peer_id = shift;
  return $self->set_peer_role({
    peer_id => $peer_id,
    role    => 'owner'
  });
};

# Purge api keys
helper purge_api_keys => sub {
  my $self = shift;
  $self->app->log->debug('Removing expired API keys');
  my $sth = eval {
    $self->db->prepare('DELETE FROM `api_keys`
                          WHERE `not_after` < CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\')');
  };
  $sth->execute;
  return 1;
};

# Purge unused rooms
helper purge_rooms => sub {
  my $self = shift;
  $self->app->log->debug('Removing unused rooms');
  my $sth = eval {
    $self->db->prepare('SELECT `name`,`etherpad_group`
                          FROM `rooms`
                          WHERE `last_activity` < DATE_SUB(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'),
                                INTERVAL ' . $config->{'rooms.inactivity_timeout'} . ' MINUTE)
                          AND `persistent`=\'0\' AND `owner_password` IS NULL');
  };
  $sth->execute;
  my $toDelete = {};
  while (my ($room,$ether_group) = $sth->fetchrow_array){
    $toDelete->{$room} = $ether_group;
  }
  if ($config->{'rooms.reserved_inactivity_timeout'} > 0){
    $sth = eval {
      $self->db->prepare('SELECT `name`,`etherpad_group`
                            FROM `rooms`
                            WHERE `last_activity` < DATE_SUB(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'),
                                  INTERVAL ' . $config->{'rooms.reserved_inactivity_timeout'} . ' MINUTE)
                              AND `persistent`=\'0\' AND `owner_password` IS NOT NULL')
    };
    $sth->execute;
    while (my ($room, $ether_group) = $sth->fetchrow_array){
      $toDelete->{$room} = $ether_group;
    }
  }
  foreach my $room (keys %{$toDelete}){
    $self->log_event({
      event => 'room_expire',
      msg   => "Deleting room $room after inactivity timeout"
    });
    # Remove Etherpad group
    if ($optf->{etherpad}){
      $optf->{etherpad}->delete_pad($toDelete->{$room} . '$' . $room);
      $optf->{etherpad}->delete_group($toDelete->{$room});
    }
  }
  # Now remove rooms
  if (keys %{$toDelete} > 0){
    $sth = eval {
      $self->db->prepare("DELETE FROM `rooms`
                            WHERE `name` IN (" . join( ",", map { "?" } keys %{$toDelete} ) . ")");
    };
    $sth->execute(keys %{$toDelete});
  }
  return 1;
};

# delete just a specific room, by name
helper delete_room => sub {
  my $self = shift;
  my $room = shift;
  $self->app->log->debug("Removing room $room");
  my $data = $self->get_room_by_name($room);
  if (!$data){
    $self->app->log->debug("Error: room $room doesn't exist");
    return 0;
  }
  if ($optf->{etherpad} && $data->{etherpad_group}){
    $optf->{etherpad}->delete_pad($data->{etherpad_group} . '$' . $room);
    $optf->{etherpad}->delete_group($data->{etherpad_group});
  }
  my $sth = eval {
      $self->db->prepare('DELETE FROM `rooms`
                            WHERE `name`=?');
  };
  $sth->execute($room);
  $self->log_event({
    event => 'room_delete',
    msg   => "Deleting room $room"
  });
  return 1;
};

# Retrieve the list of rooms
helper get_room_list => sub {
  my $self = shift;
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `rooms`');
  };
  $sth->execute;
  return $sth->fetchall_hashref('name');
};

# Just update the activity timestamp
# so we can detect unused rooms
helper update_room_last_activity => sub {
  my $self = shift;
  my $name = shift;
  my $data = $self->get_room_by_name($name);
  if (!$data){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('UPDATE `rooms`
                          SET `last_activity`=CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\')
                          WHERE `id`=?');
  };
  $sth->execute($data->{id});
  return 1;
};

# Return an array of supported languages
helper get_supported_lang => sub {
  my $self = shift;
  return map { basename(s/\.po$//r) } glob('lib/Vroom/I18N/*.po');
};

# Generate a random token
helper get_random => sub {
  my $self    = shift;
  my $entropy = shift;
  return Session::Token->new(entropy => $entropy)->get;
};

# Generate a random name
helper get_random_name => sub {
  my $self = shift;
  my $name = lc $self->get_random(64);
  # Get another one if already taken
  while ($self->get_room_by_name($name)){
    $name = $self->get_random_name();
  }
  return $name;
};

# Add an email address to the list of notifications
helper add_notification => sub {
  my $self  = shift;
  my $room  = shift;
  my $email = shift;
  my $data = $self->get_room_by_name($room);
  if (!$data || !$self->valid_email($email)){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('INSERT INTO `email_notifications`
                          (`room_id`,`email`)
                          VALUES (?,?)');
  };
  $sth->execute(
    $data->{id},
    $email
  );
  return 1;
};

# Update the list of notified email for a room in one go
# Take the room and an array ref of emails
helper update_email_notifications => sub {
  my $self   = shift;
  my $room   = shift;
  my $emails = shift;
  my $data = $self->get_room_by_name($room);
  if (!$data){
    return 0;
  }
  my $old = $self->get_email_notifications($room);
  my @old = sort map { $old->{$_}->{email} } keys $old;
  my @new = sort @$emails;
  # Remove empty email
  @new = grep { $_ ne '' } @new;
  my $diff = Array::Diff->diff(\@old, \@new);
  # Are we changing the list of email ?
  if ($diff->count > 0){
    my $msg = "Notification list for room $room has changed\n";
    if (scalar @{$diff->deleted} > 0){
      $msg .= "Emails being removed: " . join (', ', @{$diff->deleted}) . "\n";
    }
    if (scalar @{$diff->added} > 0){
      $msg .= "Emails being added: " . join (', ', @{$diff->added}) . "\n";
    }
    $self->log_event({
      event => 'email_notification_change',
      msg   => $msg
    });
  }
  # First, drop all existing notifications
  my $sth = eval {
    $self->db->prepare('DELETE FROM `email_notifications`
                          WHERE `room_id`=?');
  };
  $sth->execute(
    $data->{id},
  );
  # Now, insert new emails
  foreach my $email (@new){
    $self->add_notification($room,$email) || return 0;
  }
  return 1;
};

# Return the list of email addresses
helper get_email_notifications => sub {
  my $self = shift;
  my $room = shift;
  $room = $self->get_room_by_name($room);
  return 0 if (!$room);
  my $sth = eval {
    $self->db->prepare('SELECT `id`,`email`
                          FROM `email_notifications`
                          WHERE `room_id`=?');
  };
  $sth->execute($room->{id});
  return $sth->fetchall_hashref('id');
};

# Randomly choose a music on hold
helper choose_moh => sub {
  my $self = shift;
  my @files = (<public/snd/moh/*.*>);
  return basename($files[rand @files]);
};

# Add a invitation
helper add_invitation => sub {
  my $self  = shift;
  my $room  = shift;
  my $email = shift;
  my $data = $self->get_room_by_name($room);
  return 0 if (!$data);
  my $token = $self->get_random(256);
  my $sth = eval {
    $self->db->prepare('INSERT INTO `email_invitations`
                          (`room_id`,`from`,`token`,`email`,`date`)
                          VALUES (?,?,?,?,CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'))');
  };
  $sth->execute(
    $data->{id},
    $self->session('id'),
    $token,
    $email
  );
  $self->log_event({
    event => 'send_invitation',
    msg   => "Invitation to join room $room sent to $email"
  });
  return $token;
};

# return a hash with all the invitation param
# just like get_room
helper get_invitation_by_token => sub {
  my $self  = shift;
  my $token = shift;
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `email_invitations`
                          WHERE `token`=?
                            AND `processed`=\'0\'');
  };
  $sth->execute($token);
  return $sth->fetchall_hashref('token')->{$token};
};

# Find invitations which have a unprocessed repsponse
helper get_invitation_list => sub {
  my $self    = shift;
  my $session = shift;
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `email_invitations`
                          WHERE `from`=?
                            AND `response` IS NOT NULL
                            AND `processed`=\'0\'');
  };
  $sth->execute($session);
  return $sth->fetchall_hashref('id');
};

# Got a response from invitation. Store the message in the DB
# so the organizer can get it
helper respond_to_invitation => sub {
  my $self     = shift;
  my $token    = shift;
  my $response = shift;
  my $message  = shift;
  my $sth = eval {
    $self->db->prepare('UPDATE `email_invitations`
                          SET `response`=?,
                              `message`=?
                          WHERE `token`=?');
  };
  $sth->execute(
    $response,
    $message,
    $token
  );
  $self->log_event({
    event => 'invitation_response',
    msg   => "Invitation ID $token received a reply"
  });
  return 1;
};

# Mark a invitation response as processed
helper mark_invitation_processed => sub {
  my $self  = shift;
  my $token = shift;
  my $sth = eval {
    $self->db->prepare('UPDATE `email_invitations`
                          SET `processed`=\'1\'
                          WHERE `token`=?');
  };
  $sth->execute($token);
  $self->log_event({
    event => 'invalidate_invitation',
    msg   => "Marking invitation $token as processed, it won't be usable anymore"
  });
  return 1;
};

# Purge expired invitation links
# Invitations older than 2 hours really doesn't make a lot of sens
helper purge_invitations => sub {
  my $self = shift;
  $self->app->log->debug('Removing expired invitations');
  my $sth = eval {
    $self->db->prepare('DELETE FROM `email_invitations`
                          WHERE `date` < DATE_SUB(CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\'), INTERVAL 2 HOUR)');
  };
  $sth->execute;
  return 1;
};

# Check an invitation token is valid
helper check_invite_token => sub {
  my $self  = shift;
  my $room  = shift;
  my $token = shift;
  # Expire invitations before checking if it's valid
  $self->purge_invitations;
  my $ret = 0;
  my $data = $self->get_room_by_name($room);
  return 0 if (!$data || !$token);
  $self->app->log->debug("Checking if invitation with token $token is valid for room $room");
  my $sth = eval {
    $self->db->prepare('SELECT COUNT(`id`)
                          FROM `email_invitations`
                          WHERE `room_id`=?
                          AND `token`=?
                          AND (`response` IS NULL
                                OR `response`=\'later\')');
  };
  $sth->execute(
    $data->{id},
    $token
  );
  my $num;
  $sth->bind_columns(\$num);
  $sth->fetch;
  if ($num != 1){
    $self->app->log->debug("Invitation is invalid");
    return 0;
  }
  $self->app->log->debug("Invitation is valid");
  return 1;
};

# Create a pad (and the group if needed)
helper create_pad => sub {
  my $self = shift;
  my $room = shift;
  my $data = $self->get_room_by_name($room);
  return 0 if (!$optf->{etherpad} || !$data);
  # Create the etherpad group if not already done
  # and register it in the DB
  if (!$data->{etherpad_group} || $data->{etherpad_group} eq ''){
    $data->{etherpad_group} = $optf->{etherpad}->create_group();
    if (!$data->{etherpad_group}){
      return 0;
    }
    my $sth = eval {
      $self->db->prepare('UPDATE `rooms`
                            SET `etherpad_group`=?
                            WHERE `id`=?');
    };
    $sth->execute(
      $data->{etherpad_group},
      $data->{id}
    );
  }
  $optf->{etherpad}->create_group_pad($data->{etherpad_group}, $room);
  $self->log_event({
    event => 'pad_create',
    msg   => "Creating group pad " . $data->{etherpad_group} . " for room $room"
  });
  return 1;
};

# Create an etherpad session for a user
helper create_etherpad_session => sub {
  my $self = shift;
  my $room = shift;
  my $data = $self->get_room_by_name($room);
  if (!$optf->{etherpad} || !$data || !$data->{etherpad_group}){
    return 0;
  }
  my $id = $optf->{etherpad}->create_author_if_not_exists_for($self->get_name);
  $self->session($room)->{etherpadAuthorId} = $id;
  my $etherpadSession = $optf->{etherpad}->create_session(
    $data->{etherpad_group},
    $id,
    time + 86400
  );
  $self->session($room)->{etherpadSessionId} = $etherpadSession;
  my $etherpadCookieParam = {};
  if ($config->{'etherpad.base_domain'} && $config->{'etherpad.base_domain'} ne ''){
    $etherpadCookieParam->{domain} = $config->{'etherpad.base_domain'};
  }
  $self->cookie(sessionID => $etherpadSession, $etherpadCookieParam);
  return 1;
};

# Get an API key by token
# just used to check if the key exists
helper get_key_by_token => sub {
  my $self  = shift;
  my $token = shift;
  if (!$token || $token eq ''){
    return 0;
  }
  my $sth = eval {
    $self->db->prepare('SELECT *
                          FROM `api_keys`
                          WHERE `token`=?
                            AND `not_after` > CONVERT_TZ(NOW(), @@session.time_zone, \'+00:00\')
                          LIMIT 1');
  };
  $sth->execute($token);
  return $sth->fetchall_hashref('token')->{$token};
};

# Associate an API key to a room, and set the corresponding role
helper associate_key_to_room => sub {
  my $self = shift;
  my $data = shift;
  my $room = $self->get_room_by_name($data->{room});
  my $key  = $self->get_key_by_token($data->{key});
  return 0 if (!$room || !$key);
  my $sth = eval {
    $self->db->prepare('INSERT INTO `room_keys`
                          (`room_id`,`key_id`,`role`)
                          VALUES (?,?,?)
                          ON DUPLICATE KEY UPDATE `role`=?');
  };
  $sth->execute(
    $room->{id},
    $key->{id},
    $data->{role},
    $data->{role}
  );
  return 1;
};

# Make an API key admin of every rooms
helper make_key_admin => sub {
  my $self  = shift;
  my $token = shift;
  my $key = $self->get_key_by_token($token);
  return 0 if (!$key);
  my $sth = eval {
    $self->db->prepare('UPDATE `api_keys`
                         SET `admin`=\'1\'
                         WHERE `id`=?');
  };
  $sth->execute($key->{id});
  $self->log_event({
    event => 'admin_key',
    msg   => "Granting API key $token admin privileges"
  });
  return 1;
};

# Get the role of an API key for a room
helper get_key_role => sub {
  my $self  = shift;
  my $token = shift;
  my $room  = shift;
  my $key = $self->get_key_by_token($token);
  if (!$key){
    $self->app->log->debug("Invalid API key");
    return 0;
  }
  # An admin key is considered owner of any room
  if ($key->{admin}){
    return 'admin';
  }
  # Now, lookup the DB the role of this key for this room
  my $sth = eval {
    $self->db->prepare('SELECT `role`
                          FROM `room_keys`
                          LEFT JOIN `rooms` ON `room_keys`.`room_id`=`rooms`.`id`
                          WHERE `room_keys`.`key_id`=?
                            AND `rooms`.`name`=?
                          LIMIT 1');
  };
  $sth->execute($key->{id},$room);
  $sth->bind_columns(\$key->{role});
  $sth->fetch;
  if ($key->{role}){
    $self->app->log->debug("Key $token has role:" . $key->{role} . " in room $room");
  }
  return $key->{role};
};

# Check if a key can perform an action against a room
helper key_can_do_this => sub {
  my $self = shift;
  my $data = shift;
  my $actions = API_ACTIONS;
  return 0 if (!$data->{action});
  # Anonymous actions
  if ($actions->{anonymous}->{$data->{action}}){
    return 1;
  }
  my $role = $self->get_key_role($data->{token}, $data->{param}->{room});
  if (!$role){
    return 0;
  }
  # API key is an admin one ?
  if ($role eq 'admin'){
    return 1;
  }
  # Global actions can only be performed by admin keys
  if (!$data->{param}->{room}){
    return 0;
  }

  # If this key has owner privileges on this room, allow both owner and partitipant actions
  if ($role eq 'owner' && ($actions->{owner}->{$data->{action}} || $actions->{participant}->{$data->{action}})){
    return 1;
  }
  # If this key has simple participant priv in this room, only allow participant actions
  elsif ($role eq 'participant' && $actions->{participant}->{$data->{action}}){
    return 1;
  }
  return 0;
};

# Get the list of members of a room
helper get_room_members => sub {
  my $self = shift;
  my $room = shift;
  return 0 if (!$self->get_room_by_name($room));
  my @p;
  foreach my $peer (keys $peers){
    if ($peers->{$peer}->{room} &&
        $peers->{$peer}->{room} eq $room){
      push @p, $peer;
    }
  }
  return @p;
};

# Broadcast a SocketIO message to all the members of a room
helper signal_broadcast_room => sub {
  my $self = shift;
  my $data = shift;

  # Send a message to all members of the same room as the sender
  # except the sender himself
  foreach my $peer (keys %$peers){
    next if $peer eq $data->{from};
    next if !$peers->{$data->{from}}->{room};
    next if !$peers->{$peer}->{room};
    next if $peers->{$peer}->{room} ne $peers->{$data->{from}}->{room};
    $peers->{$peer}->{socket}->send($data->{msg});
  }
  return 1;
};

# Get the member limit for a room
helper get_member_limit => sub {
  my $self = shift;
  my $name = shift;
  my $room = $self->get_room_by_name($name);
  if ($room->{max_members} > 0 && $room->{max_members} < $config->{'rooms.max_members'}){
    return $room->{max_members};
  }
  elsif ($config->{'rooms.max_members'} > 0){
    return $config->{'rooms.max_members'};
  }
  return 0;
};


# Get credentials for the turn servers. Return an array (username,password)
helper get_turn_creds => sub {
  my $self = shift;
  my $room = $self->get_room_by_name(shift);
  if (!$room){
    return (undef,undef);
  }
  elsif ($config->{'turn.credentials'} eq 'static'){
    return ($config->{'turn.turn_user'}, $config->{'turn.turn_password'});
  }
  elsif ($config->{'turn.credentials'} eq 'rest'){
    my $expire = time + 300;
    my $user = $expire . ':' . $room->{name};
    my $pass = encode_base64(hmac_sha1($user, $config->{'turn.secret_key'}));
    chomp $pass;
    return ($user, $pass);
  }
  return (undef, undef);
};

# Format room config as a hash to be sent in JSON response
helper get_room_conf => sub {
  my $self = shift;
  my $room = shift;
  return {
    owner_auth   => ($room->{owner_password}) ? Mojo::JSON::true : Mojo::JSON::false,
    join_auth    => ($room->{join_password})  ? Mojo::JSON::true : Mojo::JSON::false,
    locked       => ($room->{locked})         ? Mojo::JSON::true : Mojo::JSON::false,
    ask_for_name => ($room->{ask_for_name})   ? Mojo::JSON::true : Mojo::JSON::false,
    persistent   => ($room->{persistent})     ? Mojo::JSON::true : Mojo::JSON::false,
    max_members  => $room->{max_members},
    notif        => $self->get_email_notifications($room->{name})
  };
};

# Export events in XLSX
helper export_events_xlsx => sub {
  my $self   = shift;
  my $from   = shift;
  my $to     = shift;
  my $tmp    = File::Temp->new( DIR => $config->{'directories.tmp'}, SUFFIX => '.xlsx' )->filename;
  my $events = $self->get_event_list($from, $to);
  return 0 if (!$events);
  my $xlsx  = Excel::Writer::XLSX->new($tmp);
  my $sheet = $xlsx->add_worksheet;
  my @headers = qw(id date from_ip user event message);
  $sheet->set_column(1, 1, 30);
  $sheet->set_column(2, 2, 20);
  $sheet->set_column(3, 3, 60);
  $sheet->set_column(4, 4, 20);
  $sheet->set_column(5, 5, 100);
  # Write header
  $sheet->write(0, 0, \@headers);
  my $row = 1;
  foreach my $e (sort {$a <=> $b } keys %$events){
    my @details = (
      $events->{$e}->{id},
      $events->{$e}->{date},
      $events->{$e}->{from_ip},
      $events->{$e}->{user},
      $events->{$e}->{event},
      $events->{$e}->{message}
    );
    $sheet->write($row, 0, \@details);
    # Adapt row heigh depending on the number of new lines
    # in the message
    my $cr = scalar(split("\n", $events->{$e}->{message}));
    if ($cr > 1){
      $sheet->set_row($row, $cr*12);
    }
    $row++;
  }
  return $tmp;
};

# Disconnect a peer from the signaling channel
helper disconnect_peer => sub {
  my $self = shift;
  my $id   = shift;
  return 0 if (!$id || !$peers->{$id});
  if ($id && $peers->{$id} && $peers->{$id}->{room}){
    $self->log_event({
      event => 'room_leave',
      msg   => "Peer $id closed websocket connection, leaving room " . $peers->{$id}->{room}
    });
  }
  $self->signal_broadcast_room({
    from => $id,
    msg  => Protocol::SocketIO::Message->new(
      type => 'event',
      data => {
        name => 'remove',
        args => [{ id => $id, type => 'video' }]
      }
    )
  });
  $self->update_room_last_activity($peers->{$id}->{room});
  delete $peers->{$id};
};

# Socket.IO handshake
get '/socket.io/:ver' => sub {
  my $self = shift;
  my $sid  = $self->get_random(256);
  $self->session( peer_id => $sid );
  my $handshake = Protocol::SocketIO::Handshake->new(
      session_id        => $sid,
      heartbeat_timeout => 20,
      close_timeout     => 40,
      transports        => [qw/websocket/]
  );
  return $self->render(text => $handshake->to_bytes);
};

# WebSocket transport for the Socket.IO channel
websocket '/socket.io/:ver/websocket/:id' => sub {
  my $self = shift;
  my $id = $self->stash('id');
  # the ID must match the one stored in our session
  if ($id ne $self->session('peer_id')){
    $self->log_event({
      event => 'peer_id_mismatch',
      msg   => 'Something is wrong, peer ID is ' . $id . ' but should be ' . $self->session('peer_id')
    });
    return $self->send('Bad session id');
  }

  my $key = $self->session('key');

  # We create the peer in the global hash
  $peers->{$id}->{socket} = $self->tx;
  # And set the initial "last seen" flag
  $peers->{$id}->{last} = time;
  # Associate the unique ID and name
  $peers->{$id}->{id} = $self->session('id');
  $peers->{$id}->{check_invitations} = 1;
  # Register the i18n stash, for localization will be available in the main IOLoop
  # Outside of Mojo controller
  $peers->{$id}->{i18n} = $self->stash->{i18n};

  # When we recive a message, lets parse it as e Socket.IO one
  $self->on('message' => sub {
    my $self = shift;
    my $msg = Protocol::SocketIO::Message->new->parse(shift);

    if ($msg->type eq 'event'){
      # Here's a client joining a room
      if ($msg->{data}->{name} eq 'join'){
        my $room = $msg->{data}->{args}[0];
        my $role = $self->get_key_role($key, $room);
        $peers->{$id}->{role} = $role;
        # Is this peer allowed to join the room ?
        if (!$self->get_room_by_name($room) ||
            !$role ||
            $role !~ m/^(owner)|(participant)|(admin)$/){
          $self->log_event({
            event => 'no_role',
            msg   => "Failed to connect to the signaling channel, " . $self->get_name . " has no role in room $room"
          });
          $self->send( Protocol::SocketIO::Message->new( type => 'disconnect' ) );
          $self->finish;
          return;
        }
        # Are we under the limit of members ?
        my $limit = $self->get_member_limit($room);
        if ($limit > 0 && scalar $self->get_room_members($room) >= $limit){
          $self->log_event({
            event => 'member_off_limit',
            msg   => "Failed to connect to the signaling channel, members limit (" . $config->{'rooms.max_members'} .
                                 ") is reached"
          });
          $self->send( Protocol::SocketIO::Message->new( type => 'disconnect' ) );
          $self->finish;
          return;
        }
        # Lets build the list of the other peers in the room to send to this new one
        my $others = {};
        foreach my $peer (keys %$peers){
          next if $peer eq $id;
          next if !$peers->{$peer}->{room};
          next if $peers->{$peer}->{room} ne $room;
          $others->{$peer} = $peers->{$peer}->{details};
        }
        $peers->{$id}->{details} = {
          screen => \0,
          video  => \1,
          audio  => \0
        };
        $peers->{$id}->{room} = $room;
        # Lets send the list of peers in our ack message
        # Not sure why the null arg is needed, got it by looking at how it works with SignalMaster
        $self->send(
          Protocol::SocketIO::Message->new(
            type       => 'ack',
            message_id => $msg->{id},
            args => [
              undef,
              {
                clients => $others
              }
            ]
          )
        );
        $self->log_event({
          event => 'room_join',
          msg   => "Peer $id has joined room $room"
        });
        # Update room last activity
        $self->update_room_last_activity($room);
      }
      # We have a message from a peer
      elsif ($msg->{data}->{name} eq 'message'){
        $msg->{data}->{args}[0]->{from} = $id;
        my $to = $msg->{data}->{args}[0]->{to};
        # Unicast message ? Check if the dest is in the same room
        # and send
        if ($to &&
            $peers->{$to} &&
            $peers->{$to}->{room} &&
            $peers->{$to}->{room} eq $peers->{$id}->{room} &&
            $peers->{$to}->{socket}){
          $peers->{$to}->{socket}->send(Protocol::SocketIO::Message->new(%$msg));
        }
        # No dest, multicast this to every members of the room
        else{
          $self->signal_broadcast_room({
            from => $id,
            msg  => Protocol::SocketIO::Message->new(%$msg)
          });
        }
      }
      # When a peer shares its screen
      elsif ($msg->{data}->{name} eq 'shareScreen'){
        $peers->{$id}->{details}->{screen} = \1;
      }
      # Or unshares it
      elsif ($msg->{data}->{name} eq 'unshareScreen'){
        $peers->{$id}->{details}->{screen} = \0;
        $self->signal_broadcast_room({
          from => $id,
          msg  => Protocol::SocketIO::Message->new(
            type => 'event',
            data => {
              name => 'remove',
              args => [{ id => $id, type => 'screen' }]
            }
          )
        });
      }
      elsif ($msg->{data}->{name} =~ m/^leave|disconnect$/){
        $peers->{$id}->{socket}->{finish};
      }
      else{
        $self->app->log->debug("Unhandled SocketIO message\n" . Dumper $msg);
      }
    }
    # Heartbeat reply, update timestamp
    elsif ($msg->type eq 'heartbeat'){
      $peers->{$id}->{last} = time;
      # Update room last activity ~ every 40 heartbeats, so about every 2 minutes
      if ((int (rand 200)) <= 5){
        $self->update_room_last_activity($peers->{$id}->{room});
      }
    }
  });

  # Triggerred when a websocket connection ends
  $self->on(finish => sub {
    my $self   = shift;
    $self->disconnect_peer($id);
    delete $peers->{$id};
  });

  # This is just the end of the initial handshake, we indicate the client we're ready
  $self->send(Protocol::SocketIO::Message->new( type => 'connect' ));
};

# Send heartbeats to all websocket clients
# Every 3 seconds
Mojo::IOLoop->recurring( 3 => sub {
  foreach my $id (keys %{$peers}){
    # This shouldn't happen, but better to log an error and fix it rather
    # than looping indefinitly on a bogus entry if something went wrong
    if (!$peers->{$id}->{socket}){
      app->log->debug("Garbage found in peers (peer $id has no socket)\n");
      delete $peers->{$id};
    }
    # If we had no reply from this peer in the last 15 sec
    # (5 heartbeat without response), we consider it dead and remove it
    elsif ($peers->{$id}->{last} < time - 15){
      app->log->debug("Peer $id didn't reply in 15 sec, disconnecting");
      $peers->{$id}->{socket}->finish;
      app->disconnect_peer($id);
    }
    elsif ($peers->{$id}->{check_invitations}) {
      my $invitations = app->get_invitation_list($peers->{$id}->{id});
      foreach my $invit (keys %{$invitations}){
        my $msg = '';
        $msg .= sprintf($peers->{$id}->{i18n}->localize('INVITE_REPONSE_FROM_s'), $invitations->{$invit}->{email}) . "\n" ;
        if ($invitations->{$invit}->{response} && $invitations->{$invit}->{response} eq 'later'){
          $msg .= $peers->{$id}->{i18n}->localize('HE_WILL_TRY_TO_JOIN_LATER');
        }
        else{
          $msg .= $peers->{$id}->{i18n}->localize('HE_WONT_JOIN');
        }
        if ($invitations->{$invit}->{message} && $invitations->{$invit}->{message} ne ''){
          $msg .= "\n" . $peers->{$id}->{i18n}->localize('MESSAGE') . ":\n" . $invitations->{$invit}->{message} . "\n";
        }
        app->mark_invitation_processed($invitations->{$invit}->{token});
        $peers->{$id}->{socket}->send(
          Protocol::SocketIO::Message->new(
            type => 'event',
            data  => {
              name => 'notification',
              args => [{
                payload => {msg => $msg, class => 'info'}
              }]
            }
          )
        );
        delete $peers->{$id}->{check_invitations};
      }
      # Send the heartbeat
      $peers->{$id}->{socket}->send(Protocol::SocketIO::Message->new( type => 'heartbeat' ))
    }
  }
});

# Maintenance loop
# purge old stuff from the database
Mojo::IOLoop->recurring( 3600 => sub {
  app->purge_rooms;
  app->purge_invitations;
  app->update_session_keys;
});

# Route / to the index page
get '/' => sub {
  my $self = shift;
  $self->login;
  $self->stash(
    page     => 'index'
  );
} => 'index';

# Route for the about page
get '/about' => sub {
  my $self = shift;
  $self->stash(
    page       => 'about',
    components => COMPONENTS,
    musics     => MOH
  );
} => 'about';

# Documentation
get '/documentation' => sub {
  my $self = shift;
  $self->stash(
    page => 'documentation'
  );
} => 'documentation';

# Route for feedback form
any [ qw(GET POST) ] => '/feedback' => sub {
  my $self = shift;
  if ($self->req->method eq 'GET'){
    return $self->render('feedback',
      page => 'feedback'
    );
  }
  my $email = $self->param('email');
  if ($email && $email ne '' && !$self->valid_email($email)){
    return $self->render('error',
      err  => 'ERROR_MAIL_INVALID',
      msg  => $self->l('ERROR_MAIL_INVALID'),
      room => ''
    );
  }
  my $comment = $self->param('comment');
  my $sent    = $self->mail(
    to      => $config->{'email.contact'},
    subject => $self->l("FEEDBACK_FROM_VROOM"),
    data    => $self->render_mail('feedback',
      email   => $email,
      comment => $comment
    )
  );
  return $self->render('feedback_thanks');
};

# Route for the goodbye page, displayed when someone leaves a room
get '/goodbye/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  if (!$self->get_room_by_name($room)){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  $self->logout($room);
} => 'goodbye';

# Route for the kicked page
# Should be merged with the goodby route
get '/kicked/(:room)' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  if (!$self->get_room_by_name($room)){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  $self->logout($room);
} => 'kicked';

# Route for invitition response
any [ qw(GET POST) ] => '/invitation/:token' => { token => '' } => sub {
  my $self = shift;
  my $token = $self->stash('token');
  # Delete expired invitation now
  $self->purge_invitations;
  my $invite = $self->get_invitation_by_token($token);
  my $room = $self->get_room_by_id($invite->{room_id});
  if (!$invite || !$room){
    return $self->render('error',
      err  => 'ERROR_INVITATION_INVALID',
      msg  => $self->l('ERROR_INVITATION_INVALID'),
      room => $room
    );
  }
  if ($self->req->method eq 'GET'){
    return $self->render('invitation',
      token => $token,
      room  => $room->{name},
    );
  }
  elsif ($self->req->method eq 'POST'){
    my $response = $self->param('response') || 'decline';
    my $message = $self->param('message') || '';
    if ($response !~ m/^(later|decline)$/ || !$self->respond_to_invitation($token, $response, $message)){
      return $self->render('error',
        err  => 'ERROR_INVITATION_INVALID',
        msg  => $self->l('ERROR_INVITATION_INVALID'),
        room => $room
      );
    }
    return $self->render('invitation_thanks');
  }
  return $self->render('error',
    err  => 'ERROR_OCCURRED',
    msg  => $self->l('ERROR_OCCURRED'),
    room => $room
  );
};

# Create a json script which contains localization
get '/locales/(:lang).js' => sub {
  my $self = shift;
  my $usr_lang = $self->languages;
  my $req_lang = $self->stash('lang');
  $req_lang = 'en' unless grep { $_ eq $req_lang } $self->get_supported_lang;
  # Temporarily switch to the requested locale
  # eg, we can be in en and ask for /locales/fr.js
  $self->languages($req_lang);
  my $strings = {};
  my $fallback_strings = {};
  foreach my $string (keys %Vroom::I18N::fr::Lexicon){
    next if $string eq '';
    if ($self->l($string) ne ''){
      $strings->{$string} = $self->l($string);
    }
    else{
      $self->languages('en');
      $strings->{$string} = $self->l($string);
      $self->languages($req_lang);
    }
  }
  # Set the user locale back
  $self->languages($usr_lang);
  # And send the response
  return $self->render(
    text   => 'locale = ' . Mojo::JSON::to_json($strings) . ';',
    format => 'application/javascript;charset=UTF-8'
  );
};

# API requests handler
any '/api' => sub {
  my $self = shift;
  $self->purge_api_keys;
  my $token = $self->req->headers->header('X-VROOM-API-Key');
  my $req = Mojo::JSON::decode_json($self->param('req'));
  my $room;
  if (!$req->{action} || !$req->{param}){
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED'
      },
      status => 503
    );
  }
  # Handle requests authorized for anonymous users righ now
  if ($req->{action} eq 'switch_lang'){
    if (!grep { $req->{param}->{language} eq $_ } $self->get_supported_lang()){
      return $self->render(
        json => {
          msg => $self->l('UNSUPPORTED_LANG'),
          err => 'UNSUPPORTED_LANG'
        },
        status => 400
      );
    }
    $self->session(language => $req->{param}->{language});
    return $self->render(
      json => {}
    );
  }

  # Now, lets check if the key can do the requested action
  my $res = $self->key_can_do_this({
    token  => $token,
    action => $req->{action},
    param  => $req->{param}
  });

  # This action isn't possible with the privs associated to the API Key
  if (!$res){
    $self->log_event({
      event => 'api_action_denied',
      msg   => "Key $token called $req->{action} but has been denied"
    });
    return $self->render(
      json => {
        msg => $self->l('NOT_ALLOWED'),
        err => 'NOT_ALLOWED'
      },
      status => '401'
    );
  }

  if (!grep { $_ eq $req->{action} } API_NO_LOG){
    $self->log_event({
      event => 'api_action_allowed',
      msg   => "Key $token called $req->{action}"
    });
  }

  # Here are methods not tied to a room
  if ($req->{action} eq 'get_room_list'){
    my $rooms = $self->get_room_list;
    foreach my $r (keys %{$rooms}){
      # Blank out a few param we don't need
      foreach my $p (qw/join_password owner_password owner etherpad_group/){
        delete $rooms->{$r}->{$p};
      }
      # Count active users
      $rooms->{$r}->{members} = scalar $self->get_room_members($r);
    }
    return $self->render(
      json => {
        rooms => $rooms
      }
    );
  }
  elsif ($req->{action} eq 'get_event_list'){
    my $start = $req->{param}->{start};
    my $end   = $req->{param}->{end};
    if ($start eq ''){
      $start = DateTime->now->ymd;
    }
    if ($end eq ''){
      $end = DateTime->now->ymd;
    }
    # Validate input
    if (!$self->valid_date($start) || !$self->valid_date($end)){
      return $self->render(
        json => {
          err    => 'ERROR_INPUT_INVALID',
          msg    => $self->l('ERROR_INPUT_INVALID'),
          status => 'error'
        },
      );
    }
    my $events = $self->get_event_list($start,$end);
    foreach my $event (keys %{$events}){
      # Init NULL values to empty strings
      foreach (qw(date from_ip event user message)){
        if (!$events->{$event}->{$_}){
          $events->{$event}->{$_} = '';
        }
      }
    }
    # And send the list of event as a json object
    return $self->render(
      json => {
        events => $events
      }
    );
  }
  # And here anonymous method, which do not require an API Key
  elsif ($req->{action} eq 'create_room'){
    $req->{param}->{room} ||= $self->get_random_name();
    $req->{param}->{room} = lc $req->{param}->{room};
    my $json = {
      err  => 'ERROR_OCCURRED',
      msg  => $self->l('ERROR_OCCURRED'),
      room => $req->{param}->{room}
    };
    $self->login;
    # Cleanup unused rooms before trying to create it
    $self->purge_rooms;
    if (!$self->valid_room_name($req->{param}->{room})){
      $json->{err} = 'ERROR_NAME_INVALID';
      $json->{msg} = $self->l('ERROR_NAME_INVALID');
      return $self->render(json => $json, status => 400);
    }
    elsif ($self->get_room_by_name($req->{param}->{room})){
      $json->{err} = 'ERROR_NAME_CONFLICT';
      $json->{msg} = $self->l('ERROR_NAME_CONFLICT');
      return $self->render(json => $json, status => 409);
    }
    if (!$self->create_room($req->{param}->{room})){
      $json->{err} = 'ERROR_OCCURRED';
      $json->{msg} = $self->l('ERROR_OCCURRED');
      return $self->render(json => $json, status => 500);
    }
    $json->{err} = '';
    $self->associate_key_to_room({
      room => $req->{param}->{room},
      key  => $token,
      role => 'owner'
    });
    return $self->render(json => $json);
  }

  if (!$req->{param}->{room}){
    return $self->render(
      json => {
        msg => $self->l('ERROR_ROOM_NAME_MISSING'),
        err => 'ERROR_ROOM_NAME_MISSING'
      },
      status => '400'
    );
  }

  $room = $self->get_room_by_name($req->{param}->{room});
  if (!$room){
    return $self->render(
      json => {
        msg => sprintf($self->l('ERROR_ROOM_s_DOESNT_EXIST'), $req->{param}->{room}),
        err => 'ERROR_ROOM_DOESNT_EXIST'
      },
      status => '400'
    );
  }

  # Ok, now, we don't have to bother with authorization anymore
  if ($req->{action} eq 'authenticate'){
    my $pass = $req->{param}->{password};
    my $role = $self->get_key_role($token, $room->{name});
    my $reason;
    my $code = 401;
    if ($room->{owner_password} && Crypt::SaltedHash->validate($room->{owner_password}, $pass)){
      $role = 'owner';
    }
    elsif (!$role && $room->{join_password} && Crypt::SaltedHash->validate($room->{join_password}, $pass)){
      $role = 'participant';
    }
    elsif (!$role && !$room->{join_password} && !$room->{locked}){
      $role = 'participant';
    }
    if ($role){
      if (!$self->session($room->{name})){
        $self->session($room->{name} => {});
      }
      if ($optf->{etherpad} && !$self->session($room->{name})->{etherpadSession}){
        $self->create_etherpad_session($room->{name});
      }
      if ($self->session('peer_id')){
        $self->set_peer_role({ peer_id => $self->session('peer_id'), role => $role });
      }
      $self->associate_key_to_room({
        room => $room->{name},
        key  => $token,
        role => $role
      });
      return $self->render(
        json => {
          msg     => $self->l('AUTH_SUCCESS'),
          role    => $role,
        }
      );
    }
    elsif ($room->{locked} && $room->{owner_password}){
      $reason = $self->l('ROOM_LOCKED_ENTER_OWNER_PASSWORD');
    }
    elsif ($room->{locked}){
      $reason = sprintf($self->l('ERROR_ROOM_s_LOCKED'), $room->{name});
      $code = 403;
    }
    elsif ((!$pass || $pass eq '') && $room->{join_password}){
      $reason = $self->l('A_PASSWORD_IS_NEEDED_TO_JOIN')
    }
    elsif ($room->{join_password}){
      $reason = $self->l('WRONG_PASSWORD');
    }
    return $self->render(
      json => {
        msg => $reason
      },
      status => $code
    );
  }
  elsif ($req->{action} eq 'invite_email'){
    my $rcpts = $req->{param}->{rcpts};
    foreach my $addr (@$rcpts){
      if (!$self->valid_email($addr) && $addr ne ''){
        return $self->render(
          json => {
            msg => $self->l('ERROR_MAIL_INVALID'),
            err => 'ERROR_MAIL_INVALID'
          },
          status => 400
        );
      }
    }
    foreach my $addr (@$rcpts){
      my $token = $self->add_invitation(
        $req->{param}->{room},
        $addr
      );
      my $sent = $self->mail(
        to      => $addr,
        subject => $self->l("EMAIL_INVITATION"),
        data    => $self->render_mail('invite',
          room     => $req->{param}->{room},
          message  => $req->{param}->{message},
          token    => $token,
          joinPass => ($room->{join_password}) ? 'yes' : 'no'
        )
      );
      if (!$token || !$sent){
        return $self->render(
          json => {
            msg => $self->l('ERROR_OCCURRED'),
            err => 'ERROR_OCCURRED'
          },
          status => 400
        );
      }
      $self->app->log->info("Email invitation to join room " . $req->{param}->{room} . " sent to " . $addr);
    }
    $peers->{$self->session('peer_id')}->{check_invitations} = 1;
    return $self->render(
      json => {
        msg => sprintf($self->l('INVITE_SENT_TO_s'), join("\n", @$rcpts)),
       }
    );
  }
  # Handle room lock/unlock
  elsif ($req->{action} =~ m/(un)?lock_room/){
    $room->{locked} = ($req->{action} eq 'lock_room') ? '1':'0';
    if ($self->modify_room($room)){
      my $m = ($req->{action} eq 'lock_room') ? 'ROOM_LOCKED' : 'ROOM_UNLOCKED';
      return $self->render(
        json => {
          msg => $self->l($m),
          err => $m
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  # Update room configuration
  elsif ($req->{action} eq 'update_room_conf'){
    $room->{locked} = ($req->{param}->{locked}) ? '1' : '0';
    $room->{ask_for_name} = ($req->{param}->{ask_for_name}) ? '1' : '0';
    $room->{max_members} = $req->{param}->{max_members};
    # Room persistence can only be set by admins
    if ($req->{param}->{persistent} ne '' && $self->key_can_do_this({token => $token, action => 'set_persistent'})){
      $room->{persistent} = ($req->{param}->{persistent} eq Mojo::JSON::true) ? '1' : '0';
    }
    foreach my $pass (qw/join_password owner_password/){
      if ($req->{param}->{$pass} eq Mojo::JSON::false){
        $room->{$pass} = undef;
      }
      elsif ($req->{param}->{$pass} ne ''){
        $room->{$pass} = Crypt::SaltedHash->new(algorithm => 'SHA-256')->add($req->{param}->{$pass})->generate;
      }
    }
    if ($self->modify_room($room) && $self->update_email_notifications($room->{name},$req->{param}->{emails})){
      return $self->render(
        json => {
          msg => $self->l('ROOM_CONFIG_UPDATED')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED'
      },
      staus => 503
    );
  }
  # Handle password (join and owner)
  elsif ($req->{action} eq 'set_join_password'){
    $room->{join_password} = ($req->{param}->{password} && $req->{param}->{password} ne '') ?
      Crypt::SaltedHash->new(algorithm => 'SHA-256')->add($req->{param}->{password})->generate : undef;
    if ($self->modify_room($room)){
      return $self->render(
        json => {
          msg => $self->l(($req->{param}->{password}) ? 'PASSWORD_PROTECT_SET' : 'PASSWORD_PROTECT_UNSET'),
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  elsif ($req->{action} eq 'set_owner_password'){
    if (grep { $req->{param}->{room} eq $_ } (split /[,;]/, $config->{'rooms.common_names'})){
      return $self->render(
        json => {
          msg => $self->l('ERROR_COMMON_ROOM_NAME'),
          err => 'ERROR_COMMON_ROOM_NAME'
        },
        status => 406
      );
    }
    $room->{owner_password} = ($req->{param}->{password} && $req->{param}->{password} ne '') ?
      Crypt::SaltedHash->new(algorithm => 'SHA-256')->add($req->{param}->{password})->generate : undef;
    if ($self->modify_room($room)){
      return $self->render(
        json => {
          msg => $self->l(($req->{param}->{password}) ? 'ROOM_NOW_RESERVED' : 'ROOM_NO_MORE_RESERVED'),
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  elsif ($req->{action} eq 'set_persistent'){
    my $set = $self->param('set');
    $room->{persistent} = ($set eq 'on') ? 1 : 0;
    if ($self->modify_room($room)){
      return $self->render(
        json => {
          msg => $self->l(($set eq 'on') ? 'ROOM_NOW_PERSISTENT' : 'ROOM_NO_MORE_PERSISTENT')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  # Set/unset askForName
  elsif ($req->{action} eq 'set_ask_for_name'){
    my $set = $req->{param}->{set};
    $room->{ask_for_name} = ($set eq 'on') ? 1 : 0;
    if ($self->modify_room($room)){
      return $self->render(
        json => {
          msg => $self->l(($set eq 'on') ? 'FORCE_DISPLAY_NAME' : 'NAME_WONT_BE_ASKED')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  # Return configuration for SimpleWebRTC
  elsif ($req->{action} eq 'get_rtc_conf'){
    my $resp = {
      url => Mojo::URL->new($self->url_for('/')->to_abs)->scheme('https'),
      peerConnectionConfig => {
        iceServers => []
      },
      autoRequestMedia => Mojo::JSON::true,
      enableDataChannels => Mojo::JSON::true,
      debug => Mojo::JSON::false,
      detectSpeakingEvents => Mojo::JSON::true,
      adjustPeerVolume => Mojo::JSON::false,
      autoAdjustMic => Mojo::JSON::false,
      harkOptions => {
        interval => 300,
        threshold => -20
      },
      media => {
        audio => Mojo::JSON::true,
        video => {
          mandatory => {
            maxFrameRate => $config->{'video.frame_rate'}
          }
        }
      },
      localVideo => {
        autoplay => Mojo::JSON::true,
        mirror => Mojo::JSON::false,
        muted => Mojo::JSON::true
      }
    };
    if ($config->{'turn.stun_server'}){
      if (ref $config->{'turn.stun_server'} ne 'ARRAY'){
        $config->{'turn.stun_server'} = [ $config->{'turn.stun_server'} ];
      }
      foreach my $s (@{$config->{'turn.stun_server'}}){
        push @{$resp->{peerConnectionConfig}->{iceServers}}, { url => $s };
      }
    }
    if ($config->{'turn.turn_server'}){
      if (ref $config->{'turn.turn_server'} ne 'ARRAY'){
        $config->{'turn.turn_server'} = [ $config->{'turn.turn_server'} ];
      }
      foreach my $t (@{$config->{'turn.turn_server'}}){
        my $turn = { url => $t };
        ($turn->{username},$turn->{credential}) = $self->get_turn_creds($room->{name});
        push @{$resp->{peerConnectionConfig}->{iceServers}}, $turn;
      }
    }
    return $self->render(
      json => {
        config => $resp
      }
    );
  }
  # Return just room config
  elsif ($req->{action} eq 'get_room_conf'){
    my $resp = $self->get_room_conf($room);
    my $role = $self->get_key_role($token,$room->{name});
    if (!$role || $role !~ m/^admin|owner$/){
      $self->app->log->debug("API Key $token is not admin, nor owner of room " . $room->{name} . ", blanking out sensible data");
      $resp->{notif} = {};
    }
    return $self->render(
      json => $resp
    );
  }
  # Return the role of a peer
  elsif ($req->{action} eq 'get_peer_role'){
    my $peer_id = $req->{param}->{peer_id};
    if (!$peer_id){
      return $self->render(
        json => {
          msg => $self->l('ERROR_PEER_ID_MISSING'),
          err => 'ERROR_PEER_ID_MISSING'
        },
        status => 400
      );
    }
    if ($self->session('peer_id') && $self->session('peer_id') eq $peer_id){
      my $api_role = $self->get_key_role($token,$room->{name});
      # If we just have been promoted to owner
      if ($api_role ne 'owner' &&
          $self->get_peer_role($peer_id) &&
          $self->get_peer_role($peer_id) eq 'owner'){
        $self->associate_key_to_room({
          room => $room->{name},
          key  => $token,
          role => 'owner'
        });
        if (!$res){
          return $self->render(
            json => {
              msg => $self->l('ERROR_OCCURRED'),
              err => 'ERROR_OCCURRED'
            },
            status => 503
          );
        }
      }
    }
    my $role = $self->get_peer_role($peer_id);
    # In a room, an admin is just equivalent to an owner
    $role = ($role eq 'admin') ? 'owner' : $role;
    if (!$role){
      return $self->render(
        json => {
          msg => $self->l('ERROR_PEER_NOT_FOUND'),
          err => 'ERROR_PEER_NOT_FOUND'
        },
        status => 400
      );
    }
    return $self->render(
      json => {
        role => $role,
      }
    );
  }
  # Notify the backend when we join a room
  elsif ($req->{action} eq 'join'){
    my $name = $req->{param}->{name} || '';
    my $peer_id = $req->{param}->{peer_id};
    my $subj = sprintf($self->l('s_JOINED_ROOM_s'), ($name eq '') ? $self->l('SOMEONE') : $name, $room->{name});
    # Send notifications
    my $recipients = $self->get_email_notifications($room->{name});
    foreach my $rcpt (keys %{$recipients}){
      $self->app->log->debug('Sending an email to ' . $recipients->{$rcpt}->{email});
      my $sent = $self->mail(
        to      => $recipients->{$rcpt}->{email},
        subject => $subj,
        data    => $self->render_mail('notification',
          room => $room->{name},
          name => $name
        )
      );
    }
    return $self->render(
      json => {}
    );
  }
  # Promote a participant to be owner of a room
  elsif ($req->{action} eq 'promote_peer'){
    my $peer_id = $req->{param}->{peer_id};
    if (!$peer_id){
      return $self->render(
        json => {
          msg => $self->l('ERROR_PEER_ID_MISSING'),
          err => 'ERROR_PEER_ID_MISSING'
        },
        status => 400
      );
    }
    elsif ($self->promote_peer($peer_id)){
      return $self->render(
        json => {
          msg => $self->l('PEER_PROMOTED')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED'
      },
      status => 503
    );
  }
  # Wipe room data (chat history and etherpad content)
  elsif ($req->{action} eq 'wipe_data'){
    if (!$optf->{etherpad} || ($optf->{etherpad}->delete_pad($room->{etherpad_group} . '$' . $room->{name}) &&
           $self->create_pad($room->{name}) &&
           $self->create_etherpad_session($room->{name}))){
      return $self->render(
        json => {
          msg => $self->l('DATA_WIPED')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
  # Get a new etherpad session
  elsif ($req->{action} eq 'get_pad_session'){
    if ($self->create_etherpad_session($room->{name})){
      return $self->render(
        json => {
          msg => $self->l('SESSION_CREATED')
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      styaus => 503
    );
  }
  # Delete a room
  elsif ($req->{action} eq 'delete_room'){
    if ($self->delete_room($room->{name})){
      return $self->render(
        json => {
          msg => $self->l('ROOM_DELETED'),
        }
      );
    }
    return $self->render(
      json => {
        msg => $self->l('ERROR_OCCURRED'),
        err => 'ERROR_OCCURRED',
      },
      status => 503
    );
  }
};

group {
  under '/admin' => sub {
    my $self = shift;
    # For now, lets just pretend that anyone able to access
    # /admin is already logged in (auth is managed outside of VROOM)
    # TODO: support several auth method, including an internal one where user are managed
    # in our DB, and another where auth is handled by the web server
    $self->login;
     my $role = $self->get_key_role($self->session('key'), undef);
    if (!$role || $role ne 'admin'){
      $self->make_key_admin($self->session('key'));
    }
    $self->purge_rooms;
    $self->stash(page => 'admin');
    return 1;
  };

  # Admin index
  get '/' => sub {
    my $self = shift;
    return $self->render('admin');
  };

  # Room management
  get '/rooms' => sub {
    my $self = shift;
    return $self->render('admin_manage_rooms');
  };

  # Audit
  get '/audit' => sub {
    my $self = shift;
    return $self->render('admin_audit');
  };

  get '/export_events' => sub {
    my $self = shift;
    if (!$optf->{excel}){
      return $self->render('error',
        msg => $self->l('ERROR_FEATURE_NOT_AVAILABLE'),
        err => 'ERROR_FEATURE_NOT_AVAILABLE',
        room => ''
      );
    }
    my $from = $self->param('from') || DateTime->now->ymd;
    my $to   = $self->param('to')   || DateTime->now->ymd;
    my $file = $self->export_events_xlsx($from,$to);
    if (!$file || !-e $file){
      return $self->render('error',
        msg => $self->l('ERROR_EXPORT_XLSX'),
        err => 'ERROR_EXPORT_XLSX',
        room => ''
      );
    }
    $self->render_file(
      filepath => $file,
      filename => 'events.xlsx',
      cleanup  => 1,
      format   => 'vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    );
  };
};

# Catch all route: if nothing else match, it's the name of a room
get '/:room' => sub {
  my $self = shift;
  my $room = $self->stash('room');
  my $video = $self->param('video') || '1';
  my $token = $self->param('token') || undef;
  # Redirect to lower case
  if ($room ne lc $room){
    $self->redirect_to($self->get_url('/') . lc $room);
  }
  $self->purge_rooms;
  $self->purge_invitations;
  my $res = $self->valid_room_name($room);
  if (!$self->valid_room_name($room)){
    return $self->render('error',
      msg  => $self->l('ERROR_NAME_INVALID'),
      err  => 'ERROR_NAME_INVALID',
      room => $room
    );
  }
  my $data = $self->get_room_by_name($room);
  unless ($data){
    return $self->render('error',
      err  => 'ERROR_ROOM_s_DOESNT_EXIST',
      msg  => sprintf ($self->l("ERROR_ROOM_s_DOESNT_EXIST"), $room),
      room => $room
    );
  }
  # Create a session if not already done
  $self->login;
  # If we've reached the members' limit
  my $limit = $self->get_member_limit($room);
  if ($limit > 0 && scalar $self->get_room_members($room) >= $limit){
    return $self->render('error',
      msg  => $self->l("ERROR_TOO_MANY_MEMBERS"),
      err  => 'ERROR_TOO_MANY_MEMBERS',
      room => $room,
    );
  }
  if ($self->check_invite_token($room,$token)){
    $self->associate_key_to_room({
      room => $room,
      key  => $self->session('key'),
      role => 'participant'
    });
  }
  # pad doesn't exist yet ?
  if ($optf->{etherpad} && !$data->{etherpad_group}){
    $self->create_pad($room);
    # Reload data so we get the etherpad_group
    $data = $self->get_room_by_name($room);
  }
  # Now display the room page
  return $self->render('join',
    page          => 'room',
    moh           => $self->choose_moh(),
    video         => $video,
    etherpadGroup => $data->{etherpad_group},
    ua            => $self->req->headers->user_agent
  );
};

# use the templates defined in the config
push @{app->renderer->paths}, 'templates/'.$config->{'interface.template'};


app->update_session_keys;
# Set log level
app->log->level($config->{'daemon.log_level'});
# Remove timestamp, journald handles it
app->log->format(sub {
  my ($time, $level, @lines) = @_;
  return "[$level] " . join("\n", @lines) . "\n";
});
app->sessions->secure(1);
app->sessions->cookie_name('vroom');
app->hook(before_dispatch => sub {
  my $self = shift;
  # Switch to the desired language
  if ($self->session('language') && $self->session('language') ne $self->languages){
    $self->languages($self->session('language'));
  }
  # Stash the configuration hashref
  $self->stash(config => $config);

  # Check db is available
  # But don't error when user requests static assets
  if ($error && @{$self->req->url->path->parts}[-1] !~ m/\.(css|js|png|woff2?|mp3|localize\/.*)$/){
    return $self->render('error',
      msg => $self->l($error),
      err => $error,
      room => ''
    );
  }
});

if (!app->db){
  $error = 'ERROR_DB_UNAVAILABLE';
}
if (!app->check_db_version){
  $error = 'ERROR_DB_VERSION_MISMATCH';
}

# Are we running in hypnotoad ?
app->config(
  hypnotoad => {
    listen   => ['http://' . $config->{'daemon.listen_ip'} . ':' . $config->{'daemon.listen_port'}],
    pid_file => $config->{'daemon.pid_file'},
    proxy    => 1
  }
);

app->log->info('Starting VROOM daemon');
# And start, lets VROOM !!
app->start;

