#!/usr/bin/perl -w

use strict;
use FindBin;

use lib qw( $FindBin::Bin );

use Admin;

my $webapp = Admin->new();
$webapp->run();
