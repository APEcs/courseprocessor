-- phpMyAdmin SQL Dump
-- version 4.3.9
-- http://www.phpmyadmin.net
--
-- Host: localhost
-- Generation Time: Apr 19, 2015 at 11:01 AM
-- Server version: 5.6.24-log
-- PHP Version: 5.5.23-pl0-gentoo

SET SQL_MODE = "NO_AUTO_VALUE_ON_ZERO";
SET time_zone = "+00:00";


/*!40101 SET @OLD_CHARACTER_SET_CLIENT=@@CHARACTER_SET_CLIENT */;
/*!40101 SET @OLD_CHARACTER_SET_RESULTS=@@CHARACTER_SET_RESULTS */;
/*!40101 SET @OLD_COLLATION_CONNECTION=@@COLLATION_CONNECTION */;
/*!40101 SET NAMES utf8 */;

--
-- Table structure for table `auth_methods`
--

CREATE TABLE IF NOT EXISTS `auth_methods` (
  `id` tinyint(3) unsigned NOT NULL,
  `perl_module` varchar(100) NOT NULL COMMENT 'The name of the AuthMethod (no .pm extension)',
  `priority` tinyint(4) NOT NULL COMMENT 'The authentication method''s priority. -128 = max, 127 = min',
  `enabled` tinyint(1) NOT NULL COMMENT 'Is this auth method usable?'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the authentication methods supported by the system';

--
-- Dumping data for table `auth_methods`
--

INSERT INTO `auth_methods` (`id`, `perl_module`, `priority`, `enabled`) VALUES
(1, 'Webperl::AuthMethod::Database', 0, 1);

-- --------------------------------------------------------

--
-- Table structure for table `auth_methods_params`
--

CREATE TABLE IF NOT EXISTS `auth_methods_params` (
  `id` int(10) unsigned NOT NULL,
  `method_id` tinyint(4) NOT NULL COMMENT 'The id of the auth method',
  `name` varchar(40) NOT NULL COMMENT 'The parameter mame',
  `value` text NOT NULL COMMENT 'The value for the parameter'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the settings for each auth method';

--
-- Dumping data for table `auth_methods_params`
--

INSERT INTO `auth_methods_params` (`id`, `method_id`, `name`, `value`) VALUES
(1, 1, 'table', 'users'),
(2, 1, 'userfield', 'username'),
(3, 1, 'passfield', 'password');

-- --------------------------------------------------------

--
-- Table structure for table `blocks`
--

CREATE TABLE IF NOT EXISTS `blocks` (
  `id` smallint(5) unsigned NOT NULL COMMENT 'Unique ID for this block entry',
  `name` varchar(32) NOT NULL,
  `module_id` smallint(5) unsigned NOT NULL COMMENT 'ID of the module implementing this block',
  `args` varchar(128) NOT NULL COMMENT 'Arguments passed verbatim to the block module'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='web-accessible page modules';

--
-- Dumping data for table `blocks`
--

INSERT INTO `blocks` (`id`, `name`, `module_id`, `args`) VALUES
(1, 'login', 1, '');

-- --------------------------------------------------------

--
-- Table structure for table `language`
--

CREATE TABLE IF NOT EXISTS `language` (
  `id` int(10) unsigned NOT NULL,
  `name` varchar(255) COLLATE utf8_unicode_ci NOT NULL COMMENT 'The language variable name',
  `lang` varchar(8) COLLATE utf8_unicode_ci NOT NULL DEFAULT 'en' COMMENT 'The language the variable is in',
  `message` text COLLATE utf8_unicode_ci NOT NULL COMMENT 'The language variable message'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Stores language variable definitions';


-- --------------------------------------------------------

--
-- Table structure for table `log`
--

CREATE TABLE IF NOT EXISTS `log` (
  `id` int(10) unsigned NOT NULL,
  `logtime` int(10) unsigned NOT NULL COMMENT 'The time the logged event happened at',
  `user_id` int(10) unsigned DEFAULT NULL COMMENT 'The id of the user who triggered the event, if any',
  `ipaddr` varchar(16) DEFAULT NULL COMMENT 'The IP address the event was triggered from',
  `logtype` varchar(64) NOT NULL COMMENT 'The event type',
  `logdata` text COMMENT 'Any data that might be appropriate to log for this event'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores a log of events in the system.';

-- --------------------------------------------------------

--
-- Table structure for table `messages_queue`
--

CREATE TABLE IF NOT EXISTS `messages_queue` (
  `id` int(10) unsigned NOT NULL,
  `previous_id` int(10) unsigned DEFAULT NULL COMMENT 'Link to a previous message (for replies/followups/etc)',
  `created` int(10) unsigned NOT NULL COMMENT 'The unix timestamp of when this message was created',
  `creator_id` int(10) unsigned DEFAULT NULL COMMENT 'Who created this message (NULL = system)',
  `deleted` int(10) unsigned DEFAULT NULL COMMENT 'Timestamp of message deletion, marks deletion of /sending/ message.',
  `deleted_id` int(10) unsigned DEFAULT NULL COMMENT 'Who deleted the message?',
  `message_ident` varchar(128) COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'Generic identifier, may be used for message lookup after addition',
  `subject` varchar(255) COLLATE utf8_unicode_ci NOT NULL COMMENT 'The message subject',
  `body` text COLLATE utf8_unicode_ci NOT NULL COMMENT 'The message body',
  `format` enum('text','html') COLLATE utf8_unicode_ci NOT NULL DEFAULT 'text' COMMENT 'Message format, for possible extension',
  `send_after` int(10) unsigned DEFAULT NULL COMMENT 'Send message after this time (NULL = as soon as possible)'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Stores messages to be sent through Message:: modules';

-- --------------------------------------------------------

--
-- Table structure for table `messages_recipients`
--

CREATE TABLE IF NOT EXISTS `messages_recipients` (
  `message_id` int(10) unsigned NOT NULL COMMENT 'ID of the message this is a recipient entry for',
  `recipient_id` int(10) unsigned DEFAULT NULL COMMENT 'ID of the user sho should get the email',
  `email` text CHARACTER SET utf8 COLLATE utf8_unicode_ci,
  `viewed` int(10) unsigned DEFAULT NULL COMMENT 'When did the recipient view this message (if at all)',
  `deleted` int(10) unsigned DEFAULT NULL COMMENT 'When did the recipient mark their view as deleted (if at all)'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the recipients of messages';

-- --------------------------------------------------------

--
-- Table structure for table `messages_sender`
--

CREATE TABLE IF NOT EXISTS `messages_sender` (
  `message_id` int(10) unsigned NOT NULL COMMENT 'ID of the message this is a sender record for',
  `sender_id` int(10) unsigned NOT NULL COMMENT 'ID of the user who sent the message',
  `deleted` int(10) unsigned NOT NULL COMMENT 'Has the sender deleted this message from their list (DOES NOT DELETE THE MESSAGE!)'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the sender of each message, and sender-specific infor';

-- --------------------------------------------------------

--
-- Table structure for table `messages_transports`
--

CREATE TABLE IF NOT EXISTS `messages_transports` (
  `id` int(10) unsigned NOT NULL,
  `name` varchar(24) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL COMMENT 'The transport name',
  `description` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'Human readable description (or langvar name)',
  `perl_module` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL COMMENT 'The perl module implementing the message transport.',
  `enabled` tinyint(1) NOT NULL COMMENT 'Is the transport enabled?'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the list of modules that provide message delivery';

--
-- Dumping data for table `messages_transports`
--

INSERT INTO `messages_transports` (`id`, `name`, `description`, `perl_module`, `enabled`) VALUES
(1, 'email', '{L_MESSAGE_TRANSP_EMAIL}', 'Webperl::Message::Transport::Email', 1);

-- --------------------------------------------------------

--
-- Table structure for table `messages_transports_status`
--

CREATE TABLE IF NOT EXISTS `messages_transports_status` (
  `id` int(10) unsigned NOT NULL,
  `message_id` int(10) unsigned NOT NULL COMMENT 'The ID of the message this is a transport entry for',
  `transport_id` int(10) unsigned NOT NULL COMMENT 'The ID of the transport',
  `status_time` int(10) unsigned NOT NULL COMMENT 'The time the status was changed',
  `status` enum('pending','sent','failed') CHARACTER SET utf8 COLLATE utf8_unicode_ci NOT NULL DEFAULT 'pending' COMMENT 'The transport status',
  `status_message` text COMMENT 'human-readable status message (usually error messages)'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores transport status information for messages';


-- --------------------------------------------------------

--
-- Table structure for table `messages_transports_userctrl`
--

CREATE TABLE IF NOT EXISTS `messages_transports_userctrl` (
  `transport_id` int(10) unsigned NOT NULL COMMENT 'ID of the transport the user has set a control on',
  `user_id` int(10) unsigned NOT NULL COMMENT 'User setting the control',
  `enabled` tinyint(1) unsigned NOT NULL DEFAULT '1' COMMENT 'contact the user through this transport?'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Allows users to explicitly enable, or disable, specific mess';

-- --------------------------------------------------------

--
-- Table structure for table `modules`
--

CREATE TABLE IF NOT EXISTS `modules` (
  `module_id` smallint(5) unsigned NOT NULL COMMENT 'Unique module id',
  `name` varchar(80) NOT NULL COMMENT 'Short name for the module',
  `perl_module` varchar(128) NOT NULL COMMENT 'Name of the perl module in blocks/ (no .pm extension!)',
  `active` tinyint(1) unsigned NOT NULL COMMENT 'Is this module enabled?'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Available site modules, perl module names, and status';

--
-- Dumping data for table `modules`
--

INSERT INTO `modules` (`module_id`, `name`, `perl_module`, `active`) VALUES
(1, 'login', 'WebUI::Login', 1);

-- --------------------------------------------------------

--
-- Table structure for table `sessions`
--

CREATE TABLE IF NOT EXISTS `sessions` (
  `session_id` char(32) NOT NULL,
  `session_user_id` int(10) unsigned NOT NULL,
  `session_start` int(11) unsigned NOT NULL,
  `session_time` int(11) unsigned NOT NULL,
  `session_ip` varchar(40) DEFAULT NULL,
  `session_autologin` tinyint(1) unsigned NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Website sessions';

-- --------------------------------------------------------

--
-- Table structure for table `session_keys`
--

CREATE TABLE IF NOT EXISTS `session_keys` (
  `key_id` char(32) COLLATE utf8_bin NOT NULL DEFAULT '',
  `user_id` int(10) unsigned NOT NULL DEFAULT '0',
  `last_ip` varchar(40) COLLATE utf8_bin NOT NULL DEFAULT '',
  `last_login` int(11) unsigned NOT NULL DEFAULT '0'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_bin COMMENT='Autologin keys';

-- --------------------------------------------------------

--
-- Table structure for table `session_variables`
--

CREATE TABLE IF NOT EXISTS `session_variables` (
  `session_id` char(32) NOT NULL,
  `var_name` varchar(80) NOT NULL,
  `var_value` text NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Session-related variables';

-- --------------------------------------------------------

--
-- Table structure for table `settings`
--

CREATE TABLE IF NOT EXISTS `settings` (
  `name` varchar(255) COLLATE utf8_unicode_ci NOT NULL,
  `value` text COLLATE utf8_unicode_ci NOT NULL
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COLLATE=utf8_unicode_ci COMMENT='Site settings';

--
-- Dumping data for table `settings`
--

INSERT INTO `settings` (`name`, `value`) VALUES
('Auth:allow_autologin', '1'),
('Auth:ip_check', '4'),
('Auth:max_autologin_time', '30'),
('Auth:session_gc', '0'),
('Auth:session_length', '3600'),
('Auth:unique_id', '1515'),
('Core:admin_email', 'support@cs.manchester.ac.uk'),
('Core:envelope_address', 'support@cs.manchester.ac.uk'),
('Log:all_the_things', '1'),
('Login:allow_self_register', '1'),
('Login:self_register_answer', 'orange'),
('Login:self_register_question', 'Which of these colours is also a fruit? Blue, orange, red'),
('Message::Transport::Email::smtp_host', 'localhost'),
('Message::Transport::Email::smtp_port', '25'),
('Notification:hold_delay', '1'),
('Session:lastgc', '0'),
('base', '/home/chris/courseprocessor/htdocs'),
('cookie_domain', ''),
('cookie_name', 'webui'),
('cookie_path', '/'),
('cookie_secure', '0'),
('datefmt', '%d %b %Y'),
('default_authmethod', '1'),
('default_block', 'loglist'),
('default_style', 'default'),
('httphost', 'https://azad.cs.man.ac.uk/'),
('jsdirid', '81bc232'),
('logfile', ''),
('scriptpath', '/webui'),
('site_name', 'Courseprocessor Web UI'),
('timefmt', '%d %b %Y %H:%M:%S %Z');

-- --------------------------------------------------------

--
-- Table structure for table `users`
--

CREATE TABLE IF NOT EXISTS `users` (
  `user_id` int(10) unsigned NOT NULL,
  `user_auth` tinyint(3) unsigned DEFAULT NULL COMMENT 'Id of the user''s auth method',
  `user_type` tinyint(3) unsigned DEFAULT '0' COMMENT 'The user type, 0 = normal, 3 = admin',
  `username` varchar(32) NOT NULL,
  `realname` varchar(128) DEFAULT NULL,
  `password` char(59) DEFAULT NULL,
  `password_set` int(10) unsigned DEFAULT NULL,
  `force_change` tinyint(1) unsigned NOT NULL DEFAULT '0' COMMENT 'Should the user be forced to change the password?',
  `fail_count` tinyint(3) unsigned NOT NULL DEFAULT '0' COMMENT 'How many login failures has this user had?',
  `email` varchar(255) CHARACTER SET utf8 COLLATE utf8_unicode_ci DEFAULT NULL COMMENT 'User''s email address',
  `created` int(10) unsigned NOT NULL COMMENT 'The unix time at which this user was created',
  `activated` int(10) unsigned DEFAULT NULL COMMENT 'Is the user account active, and if so when was it activated?',
  `act_code` varchar(64) DEFAULT NULL COMMENT 'Activation code the user must provide when activating their account',
  `last_login` int(10) unsigned NOT NULL COMMENT 'The unix time of th euser''s last login'
) ENGINE=MyISAM DEFAULT CHARSET=utf8 COMMENT='Stores the local user data for each user in the system';

--
-- Dumping data for table `users`
--

INSERT INTO `users` (`user_id`, `user_auth`, `user_type`, `username`, `realname`, `password`, `password_set`, `force_change`, `fail_count`, `email`, `created`, `activated`, `act_code`, `last_login`) VALUES
(1, NULL, 0, 'anonymous', NULL, NULL, NULL, 0, 0, NULL, 1338463934, 1338463934, NULL, 1338463934);

--
-- Indexes for dumped tables
--

--
-- Indexes for table `auth_methods`
--
ALTER TABLE `auth_methods`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `auth_methods_params`
--
ALTER TABLE `auth_methods_params`
  ADD PRIMARY KEY (`id`), ADD KEY `method_id` (`method_id`);

--
-- Indexes for table `blocks`
--
ALTER TABLE `blocks`
  ADD PRIMARY KEY (`id`), ADD UNIQUE KEY `name` (`name`);

--
-- Indexes for table `language`
--
ALTER TABLE `language`
  ADD PRIMARY KEY (`id`), ADD KEY `name` (`name`,`lang`);

--
-- Indexes for table `log`
--
ALTER TABLE `log`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `messages_queue`
--
ALTER TABLE `messages_queue`
  ADD PRIMARY KEY (`id`), ADD KEY `created` (`created`), ADD KEY `deleted` (`deleted`), ADD KEY `message_ident` (`message_ident`), ADD KEY `previous_id` (`previous_id`);

--
-- Indexes for table `messages_recipients`
--
ALTER TABLE `messages_recipients`
  ADD KEY `email_id` (`message_id`), ADD KEY `recipient_id` (`recipient_id`);

--
-- Indexes for table `messages_sender`
--
ALTER TABLE `messages_sender`
  ADD KEY `message_id` (`message_id`), ADD KEY `sender_id` (`sender_id`);

--
-- Indexes for table `messages_transports`
--
ALTER TABLE `messages_transports`
  ADD PRIMARY KEY (`id`);

--
-- Indexes for table `messages_transports_status`
--
ALTER TABLE `messages_transports_status`
  ADD PRIMARY KEY (`id`), ADD KEY `message_id` (`message_id`), ADD KEY `transport_id` (`transport_id`), ADD KEY `status` (`status`);

--
-- Indexes for table `messages_transports_userctrl`
--
ALTER TABLE `messages_transports_userctrl`
  ADD KEY `transport_id` (`transport_id`), ADD KEY `user_id` (`user_id`), ADD KEY `transport_user` (`transport_id`,`user_id`);

--
-- Indexes for table `modules`
--
ALTER TABLE `modules`
  ADD PRIMARY KEY (`module_id`);

--
-- Indexes for table `sessions`
--
ALTER TABLE `sessions`
  ADD PRIMARY KEY (`session_id`), ADD KEY `session_time` (`session_time`), ADD KEY `session_user_id` (`session_user_id`);

--
-- Indexes for table `session_keys`
--
ALTER TABLE `session_keys`
  ADD PRIMARY KEY (`key_id`,`user_id`), ADD KEY `last_login` (`last_login`);

--
-- Indexes for table `session_variables`
--
ALTER TABLE `session_variables`
  ADD KEY `session_id` (`session_id`), ADD KEY `sess_name_map` (`session_id`,`var_name`);

--
-- Indexes for table `settings`
--
ALTER TABLE `settings`
  ADD PRIMARY KEY (`name`);

--
-- Indexes for table `users`
--
ALTER TABLE `users`
  ADD PRIMARY KEY (`user_id`), ADD UNIQUE KEY `username` (`username`), ADD KEY `email` (`email`);

--
-- AUTO_INCREMENT for dumped tables
--

--
-- AUTO_INCREMENT for table `auth_methods`
--
ALTER TABLE `auth_methods`
  MODIFY `id` tinyint(3) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `auth_methods_params`
--
ALTER TABLE `auth_methods_params`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `blocks`
--
ALTER TABLE `blocks`
  MODIFY `id` smallint(5) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Unique ID for this block entry';
--
-- AUTO_INCREMENT for table `language`
--
ALTER TABLE `language`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `log`
--
ALTER TABLE `log`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `messages_queue`
--
ALTER TABLE `messages_queue`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `messages_transports`
--
ALTER TABLE `messages_transports`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `messages_transports_status`
--
ALTER TABLE `messages_transports_status`
  MODIFY `id` int(10) unsigned NOT NULL AUTO_INCREMENT;
--
-- AUTO_INCREMENT for table `modules`
--
ALTER TABLE `modules`
  MODIFY `module_id` smallint(5) unsigned NOT NULL AUTO_INCREMENT COMMENT 'Unique module id';
--
-- AUTO_INCREMENT for table `users`
--
ALTER TABLE `users`
  MODIFY `user_id` int(10) unsigned NOT NULL AUTO_INCREMENT;
/*!40101 SET CHARACTER_SET_CLIENT=@OLD_CHARACTER_SET_CLIENT */;
/*!40101 SET CHARACTER_SET_RESULTS=@OLD_CHARACTER_SET_RESULTS */;
/*!40101 SET COLLATION_CONNECTION=@OLD_COLLATION_CONNECTION */;
