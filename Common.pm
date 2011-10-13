package Common;

use strict;

use FindBin;
use Config::Simple;
tie my %cfg, "Config::Simple", $FindBin::Bin.'/cfg.ini' or die "cant open config: $!";

use Net::LDAP;
use vars qw(@ISA @EXPORT);

@ISA = qw( Exporter );
@EXPORT = qw( findemail do_log _check_password _check_people );

# find a users email address given their username
# TODO: search ldap to make sure this is a valid address
#
sub findemail($) {
    my $username = shift;
    my $email = $username.'@'.$cfg{email_domain};

    return $email;
}

# add a log entry to the events table
#
sub do_log($$$$){
    my $severity = shift;
    my $text = shift;
    my $user = shift;
    my $dbh = shift;

    $dbh->do("INSERT into events (text,severity,user) values (".$dbh->quote($text).", ".$dbh->quote($severity).", ".$dbh->quote($user).")");

}

# check password for secureness
#
sub _check_password($) {
    my $password = shift;

# password must be 8 char at least and have a number
    return if length $password < 8;
    return if $password !~ /[0-9]/;

# otherwise we're good
    return 1;
}

# check ldap groups for people access
# FIXME: make schema work so this can be pushed back into apache where it belongs
sub _check_people($) {
    my $username = shift;
    my @allowed_users = ();
    my @ldap_hosts = $cfg{ldap_hosts};

    my $ldap = Net::LDAP->new($cfg{ldap_hosts}) or die "can't connect: $@";

    foreach my $group ( @{ $cfg{'allowed_groups'} } ) {
        my $mesg = $ldap->search(
                base => $cfg{ldap_search_base},
                filter => "(cn=$group)",
                );
        die "group $group found more than once" if $mesg->count > 1;

        @allowed_users = ( @allowed_users, $mesg->entry(0)->get_value('memberUid') );
    }

    # superusers always have access
    @allowed_users = ( @allowed_users, @{ $cfg{superusers} } );

    return grep /^$username$/, @allowed_users;
}

1;
