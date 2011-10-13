-- MySQL dump 8.23
--
-- Host: localhost    Database: pureftpd
---------------------------------------------------------
-- Server version	3.23.58

--
-- Table structure for table `events`
--

CREATE TABLE events (
  id int(11) NOT NULL auto_increment,
  ts timestamp(14) NOT NULL,
  user varchar(255) NOT NULL default '',
  severity enum('info','warn','err') NOT NULL default 'info',
  text text NOT NULL,
  PRIMARY KEY  (id)
) TYPE=MyISAM;

--
-- Table structure for table `users`
--

CREATE TABLE users (
  id int(11) NOT NULL auto_increment,
  username varchar(255) NOT NULL default '',
  password varchar(255) NOT NULL default '',
  home varchar(255) NOT NULL default '',
  creator varchar(255) NOT NULL default '',
  expires datetime NOT NULL default '0000-00-00 00:00:00',
  PRIMARY KEY  (id)
) TYPE=MyISAM;

