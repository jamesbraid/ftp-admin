#
# pureftpd admin
# from dropzone2 FTP admin
# Copyright (C) 2004-2006 James Braid <jamesb@loreland.org>
#

use strict;
package Admin;
use base 'CGI::Application';

# svn kung foo
my (undef, undef, $rev) = split ' ', '$Id$';
my $version = "3.$rev";

use FindBin;
use Config::Simple;
tie my %cfg, "Config::Simple", $FindBin::Bin.'/cfg.ini' or die "cant open config: $!";

use Template;
use CGI::Carp qw(fatalsToBrowser set_message);
use DBI;
use CGI::FormBuilder;
use SQL::Abstract; 
use MIME::Lite::TT;
use Data::Dumper;
use File::Copy;
use File::Path;
use Filesys::Df;
use Number::Bytes::Human qw(format_bytes);
use Common;

my $remote_user = $ENV{'REMOTE_USER'};

die "remote user not set!" unless $remote_user;
# XXX: uncomment to use authentication
#die "ERROR: Access Denied. You are not allowed to access $cfg{product}" unless _check_people($remote_user);

my $dbh = DBI->connect($cfg{db_dsn}, $cfg{db_user}, $cfg{db_pass}) or die "cant connect to db: $DBI::errstr";

$dbh->{RaiseError} = 1;
#$dbh->{PrintError} = 1;

sub cgiapp_init {
	my $self    = shift;
	my $query   = $self->query;
}

sub setup {
	my $self = shift;
	$self->start_mode('home');
	$self->run_modes(
			'home' => 'index',
			'adduser' => 'usermod',
			'chguser' => 'usermod',
			'deluser' => 'usemod',
			);
}

# main page
# TODO: pager for the user display
# 	get superusers from LDAP groups
#
sub index{
	my $self = shift;
	my $query = $self->query;

	my @superusers = @{ $cfg{superusers} };

	my $userquery = "SELECT DATE_FORMAT(expires,'%Y-%m-%d') as expires,username,home,password,id,creator from users";

    # XXX: uncomment to use authentication
	# superusers can see everything - everyone else can only see their own
    #$userquery = "$userquery WHERE creator='$remote_user'" unless (grep /^$remote_user$/, @superusers);
	
	my $users = $dbh->selectall_arrayref("$userquery ORDER by id ASC", {Slice => {}});

	my $events = $dbh->selectall_arrayref("SELECT DATE_FORMAT(ts, '%b %d  %H:%i:%s') as ts,id,user,text,severity from events order by id desc LIMIT 0,5", {Slice => {}});
	
	$self->param(tmplpar => { 
		title => $cfg{product}." - Admin",
		users => $users,
		events => $events,
		admin => 1,
		});

	my $tmplpar = $self->param('tmplpar');
	my $template =  Template->new({
			'INCLUDE_PATH'  =>  [ $cfg{template_dir}, ],
			});

	

	$tmplpar->{myurl} = $self->query->url();
	$tmplpar->{env} = \%ENV;
	$tmplpar->{cfg} = \%cfg;
	$tmplpar->{version} = $version;
	$tmplpar->{freespace} = format_bytes(df($cfg{content_dir}, 1)->{bfree});
	$tmplpar->{totalspace} = format_bytes(df($cfg{content_dir}, 1)->{blocks});

	my $junk;
	$template->process('admin-index.tt2', $tmplpar, \$junk);
	return $junk;
}

# user modification bits
# this is one big evil function that basically switches based on
# what rm is set to.
#
sub usermod {
	my $self = shift;
	my $query = $self->query;
	my $rm = $query->param('rm');

	my %tmplhash = (
				type => 'TT2',
				template => 'admin-usermod.tt2',
				variable => 'form',
				engine => {
					INCLUDE_PATH => [ $cfg{template_dir}, ],
				},
				data => {
					title => 'Add a User to '.$cfg{product},
					admin => 1,
					env => \%ENV,
					cfg => \%cfg,
					version => $version,
				},
	);

	my $form = CGI::FormBuilder->new(
			keepextras => 1,
			method => 'POST',
			fields => [qw/username password expires/],
			validate => {
				expires => '/^[0-9]{4}-(0?[1-9]|1[0-2])-?(0?[1-9]|[1-2][0-9]|3[0-1])?$/', # mysql YYYY-MM-DD
				username => '/^[a-z0-9]+$/',
				password => \&_check_password,
			},
			required => 'ALL',
			template => \%tmplhash,
            jsfunc => <<EOJS
if (form._submit.value == "Delete") { 
	if (confirm("Really DELETE this user?\\n\\nThis will DELETE ALL content associated with this user AND the user account")) return true; 
	return false; 
} else if (form._submit.value == "Cancel") { 
	return true; 
}
EOJS
	);
	
	if ($rm eq 'adduser'){

		if ($form->submitted && $form->submitted eq 'Cancel') {
			$self->header_type('redirect');
			$self->header_props(-url  => $query->url);
			return;
	
		} elsif ($form->submitted && $form->validate){
			# form is submitted - add the user
			my $sql = SQL::Abstract->new;
			my $field = $form->field;

			$tmplhash{'data'}{'title'} = 'User '.$field->{username}.' added successfully';
			$tmplhash{'data'}{'success'} = 1;
			$tmplhash{'data'}{'action'} = 'add';
			
			$field->{home} = $cfg{content_dir}.'/'.$field->{username}.'/./';
			$field->{creator} = $remote_user;
			my ($stmt, @bind) = $sql->insert('users', $field);
			$dbh->do($stmt, undef, @bind) or return $dbh->errstr;

			mkdir $cfg{content_dir}.'/'.$field->{username};

			# send email
			my $subject = $cfg{product}." user '".$field->{username}."' has been added\n";
			my $tmplparams = {
				username => $field->{username},
				password => $field->{password},
				expires => $field->{expires},
				creator => $remote_user,
				cfg => \%cfg,
			};
			
			my $msg = MIME::Lite::TT->new(
				From => $cfg{email_from},
				To => findemail($field->{creator}),
				Bcc => $cfg{notify_aswell},
				Subject => $subject,
				Template => 'mail-new-user.tt2',
				TmplParams => $tmplparams,
				TmplOptions => { INCLUDE_PATH => [ $cfg{template_dir}, ] },
				);
			$msg->send;
			
			do_log('info', "user ".$field->{username}." created", $remote_user, $dbh);
			
			return $form->confirm(template => \%tmplhash);

		} else {
			# adding a user, send blank form
			die "can't execute apg" unless ( -x $cfg{apg_path} );
			open (APG, '-|', $cfg{apg_path}, '-n', '1', '-m', '8', '-x', '10', '-M', 'NC');
			my $password = <APG>;
			close APG;
			chomp $password;
			$tmplhash{'data'}{'action'} = 'adduser';

			$form->field(name => 'username', comment => '(lowercase alphanumeric)');
			$form->field(name => 'password', value => $password, comment => '(8 characters minimum, with at least one number)' );
			$form->field(name => 'expires', comment => '&nbsp;<img src="'.$cfg{web_base}.'/include/calendar.png" id="trigger" /> <-- click here (or enter YYYY-MM-DD)', id => 'expires');

			return $form->render(submit => [qw/Add Cancel/],
			);
		}
	
	} elsif ($rm eq 'chguser') { 

		if ($form->submitted && $form->submitted eq 'Cancel') {
			$self->header_type('redirect');
			$self->header_props(-url  => $query->url);
			return;

		} elsif ($form->submitted && $form->submitted eq 'Delete'){
			my $field = $form->field;
			$tmplhash{'data'}{'title'} = 'User '.$field->{username}.' deleted successfully';
			$tmplhash{'data'}{'success'} = 1;
			$tmplhash{'data'}{'action'} = 'delete';

			$dbh->do("delete from users where username=".$dbh->quote($field->{username}));
			
			my $home = $cfg{content_dir}.'/'.$field->{username};
			
			rmtree($home) if ($field->{username} ne '' && defined $field->{username});

			$form->field(name => 'username', type => 'static', comment => undef, force => 1);
			
			do_log('info', "user ".$field->{username}." deleted", $remote_user, $dbh);
			return $form->confirm(template => \%tmplhash);
			
		} elsif ($form->submitted && $form->submitted eq 'Edit') {
			# form is submitted - update shit
			my $sql = SQL::Abstract->new;
			my $field = $form->field;
			my $username = $field->{username};
			my %where;
			
			$tmplhash{'data'}{'title'} = 'User '.$field->{username}.' changed successfully';
			$tmplhash{'data'}{'success'} = 1;
			$tmplhash{'data'}{'action'} = 'change';

			%where = (
				username => $field->{username},
			);
			
			delete $field->{username}; # username is immutable
			my ($stmt, @bind) = $sql->update('users', $field, \%where);
			$dbh->do($stmt, undef, @bind) or die $dbh->errstr;

			do_log('info', "user $username changed", $remote_user, $dbh);
			return $form->confirm(template => \%tmplhash);

		} else {
			# fill in the modify form with the details

			my $uid = $query->param('id');
			my $userref = $dbh->selectrow_hashref("SELECT DATE_FORMAT(expires,'%Y-%m-%d') as expires,username,password,creator from users where id='$uid'");
			
			$tmplhash{'data'}{'title'} = 'Modify user \''.$userref->{username}.'\'';
			
			$form->field(name => 'creator', type => 'static', force => 1);
			$form->field(name => 'username', type => 'static', comment => undef, force => 1);
			$form->field(name => 'expires', comment => '&nbsp;<img src="'.$cfg{web_base}.'/include/calendar.png" id="trigger" /> <-- click here (or enter YYYY-MM-DD)', id => 'expires');
			
			return $form->render(submit => [qw/Edit Delete Cancel/],
								values => $userref,
								template => \%tmplhash,
			);
		}
	}
}


# processes the template with parameters gathered from the application object
#
sub processtmpl {
	my ($self, $tmplname, $dropzone) = @_;
}


1;
