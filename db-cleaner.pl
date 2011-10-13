#!/usr/bin/perl
#
# database cleaner for pureftpd admin
# from dropzone2 FTP admin
# Copyright (C) 2004-2006 James Braid <jamesb@loreland.org>
#

use strict;
use FindBin;
use lib $FindBin::Bin;
use DBI;
use Data::Dumper;
use Config::Simple;
use MIME::Lite::TT;
use File::Copy;
use File::Path;
use Date::Calc qw(:all);
use Common;

tie my %cfg, "Config::Simple", $FindBin::Bin.'/cfg.ini' or die "cant open config: $!";
my $dbh = DBI->connect($cfg{db_dsn}, $cfg{db_user}, $cfg{db_pass}) or die "cant connect to db: $DBI::errstr";
$dbh->{RaiseError} = 1;
$dbh->{PrintError} = 1;

# todays date etc
my ($day,$month,$year) = (localtime)[3..5];
$year += 1900;
$month += 1;

my $template;
my $subject;

my $users = $dbh->selectall_arrayref("SELECT DATE_FORMAT(expires,'%Y-%m-%d') as expires,username,home,password,id,creator from users", {Slice => {}});

#
# the day before the account is going to expire, email a warning
# one day after it has expired, delete the account 
#

foreach (@{ $users }) {
	
	my $mail = 0;
	
	my ($db_year, $db_month, $db_day) = split '-', $_->{'expires'};
	my $dd = Delta_Days $year, $month, $day, $db_year, $db_month, $db_day;
	
	my $creator = $_->{creator};
	my $email = findemail($creator);
	my $username = $_->{username};
	my $home = $cfg{content_dir}.'/'.$username;
	
	next if !defined $username; # dangerous
	next if $username eq '';	# dangerous
	
	my %tmplparams = ( 
			cfg => \%cfg,
			username => $_->{username},
			expire_in => $dd,
			expire_date => $_->{expires},
			change_url => $cfg{web_base}.'/?rm=chguser&id='.$_->{id},
	);

	if ($dd == 7) {
	# going to expire in one week, send the creator an email with
	#  a link to extend the account
		
		do_log('info', "user $username is going to expire in one week", 'db-cleaner', $dbh);

		$subject = $cfg{product}." user '$username' will expire in one week";
		$template = 'mail-about-to-expire.tt2';
		$mail = 1;

	} elsif ($dd == 1) {
	# going to expire in one day, warn them again
		do_log('info', "user $username is going to expire in one day", 'db-cleaner', $dbh);

		$subject = $cfg{product}." user '$username' will expire in one day";
		$template = 'mail-about-to-expire.tt2';
		$mail = 1;
		
	} elsif ($dd <= -1) {
	# expired one day ago, delete the user and directory
	#

		my $sql = 'delete from users where username='.$dbh->quote($username);
		$dbh->do($sql);
		rmtree($home) if -e $home;
		do_log('info', "deleted expired user $username", 'db-cleaner', $dbh);
	}

	if ($mail) {
		my $msg = MIME::Lite::TT->new(
				From => $cfg{email_from},
				To => $email,
				Subject => $subject,
				Template => $template,
				TmplParams => \%tmplparams,
				TmplOptions => { INCLUDE_PATH => [ $cfg{template_dir}, ] },
				);
		$msg->send;
	}
}
