# frozen_string_literal: true

require File.expand_path(File.join(File.dirname(__FILE__), '..', 'mysql'))
Puppet::Type.type(:mysql_grant).provide(:mysql, parent: Puppet::Provider::Mysql) do
  desc 'Set grants for users in MySQL.'

  commands mysql_raw: 'mysql'

  def self.instances
    instance_configs = {}
    users.map do |user|
      user_string = cmd_user(user)
      query = "SHOW GRANTS FOR #{user_string};"
      begin
        grants = mysql_caller(query, 'regular')
      rescue Puppet::ExecutionFailure => e
        # Silently ignore users with no grants. Can happen e.g. if user is
        # defined with fqdn and server is run with skip-name-resolve. Example:
        # Default root user created by mysql_install_db on a host with fqdn
        # of myhost.mydomain.my: root@myhost.mydomain.my, when MySQL is started
        # with --skip-name-resolve.
        next if e.inspect.include?('There is no such grant defined for user')

        raise Puppet::Error, _('#mysql had an error ->  %{inspect}') % { inspect: e.inspect }
      end
      # Once we have the list of grants generate entries for each.
      grants.each_line do |grant|
        # Match the munges we do in the type.
        munged_grant = grant.delete("'").delete('`').delete('"')
        # Matching: GRANT (SELECT, UPDATE) PRIVILEGES ON (*.*) TO ('root')@('127.0.0.1') (WITH GRANT OPTION)
        next unless match = munged_grant.match(%r{^GRANT\s(.+)\sON\s(.+)\sTO\s(.*)@(.*?)(\s.*)?$}) # rubocop:disable Lint/AssignmentInCondition

        privileges, table, user, host, rest = match.captures
        table.gsub!('\\\\', '\\')

        # split on ',' if it is not a non-'('-containing string followed by a
        # closing parenthesis ')'-char - e.g. only split comma separated elements not in
        # parentheses
        stripped_privileges = privileges.strip.split(%r{\s*,\s*(?![^(]*\))}).map do |priv|
          # split and sort the column_privileges in the parentheses and rejoin
          if priv.include?('(')
            type, col = priv.strip.split(%r{\s+|\b}, 2)
            "#{type.upcase} (#{col.slice(1...-1).strip.split(%r{\s*,\s*}).sort.join(', ')})"
          else
            # Once we split privileges up on the , we need to make sure we
            # shortern ALL PRIVILEGES to just all.
            (priv == 'ALL PRIVILEGES') ? 'ALL' : priv.strip
          end
        end
        # Same here, but to remove OPTION leaving just GRANT.
        options = if %r{WITH\sGRANT\sOPTION}.match?(rest)
                    ['GRANT']
                  else
                    ['NONE']
                  end
        # fix double backslash that MySQL prints, so resources match
        table.gsub!('\\\\', '\\')
        # We need to return an array of instances so capture these
        name = "#{user}@#{host}/#{table}"
        if instance_configs.key?(name)
          instance_config = instance_configs[name]
          stripped_privileges.concat instance_config[:privileges]
          options.concat instance_config[:options]
        end

        sorted_privileges = stripped_privileges.uniq.sort
        mysql_v8_privileges = ['ALTER', 'ALTER ROUTINE', 'CREATE', 'CREATE ROLE', 'CREATE ROUTINE', 'CREATE TABLESPACE', 'CREATE TEMPORARY TABLES', 'CREATE USER',
                               'CREATE VIEW', 'DELETE', 'DROP', 'DROP ROLE', 'EVENT', 'EXECUTE', 'FILE', 'INDEX', 'INSERT', 'LOCK TABLES', 'PROCESS', 'REFERENCES',
                               'RELOAD', 'REPLICATION CLIENT', 'REPLICATION SLAVE', 'SELECT', 'SHOW DATABASES', 'SHOW VIEW', 'SHUTDOWN', 'SUPER', 'TRIGGER',
                               'UPDATE']

        mysql_v8_privileges_dynamic = ['APPLICATION_PASSWORD_ADMIN', 'AUDIT_ABORT_EXEMPT', 'AUDIT_ADMIN', 'AUTHENTICATION_POLICY_ADMIN', 'BACKUP_ADMIN', 'BINLOG_ADMIN',
                                       'BINLOG_ENCRYPTION_ADMIN', 'CLONE_ADMIN', 'CONNECTION_ADMIN', 'ENCRYPTION_KEY_ADMIN', 'FIREWALL_EXEMPT', 'FLUSH_OPTIMIZER_COSTS', 'FLUSH_STATUS',
                                       'FLUSH_TABLES', 'FLUSH_USER_RESOURCES', 'GROUP_REPLICATION_ADMIN', 'GROUP_REPLICATION_STREAM', 'INNODB_REDO_LOG_ARCHIVE',
                                       'INNODB_REDO_LOG_ENABLE', 'NDB_STORED_USER', 'PASSWORDLESS_USER_ADMIN', 'PERSIST_RO_VARIABLES_ADMIN', 'REPLICATION_APPLIER', 'REPLICATION_SLAVE_ADMIN',
                                       'RESOURCE_GROUP_ADMIN', 'RESOURCE_GROUP_USER', 'ROLE_ADMIN', 'SENSITIVE_VARIABLES_OBSERVER', 'SERVICE_CONNECTION_ADMIN', 'SESSION_VARIABLES_ADMIN',
                                       'SET_USER_ID', 'SHOW_ROUTINE', 'SYSTEM_USER', 'SYSTEM_VARIABLES_ADMIN', 'TABLE_ENCRYPTION_ADMIN', 'XA_RECOVER_ADMIN']

        # rubocop:disable Layout/LineLength
        if (newer_than('mysql' => '8.0.0') && (sorted_privileges == mysql_v8_privileges)) || sorted_privileges - mysql_v8_privileges_dynamic == ["ALL"]
          sorted_privileges = ['ALL']
        end
        # rubocop:enable Layout/LineLength

        instance_configs[name] = {
          privileges: sorted_privileges,
          table: table,
          user: "#{user}@#{host}",
          options: options.uniq
        }
      end
    end
    instances = []
    instance_configs.map do |name, config|
      instances << new(
        name: name,
        ensure: :present,
        privileges: config[:privileges],
        table: config[:table],
        user: config[:user],
        options: config[:options],
      )
    end
    instances
  end

  def self.prefetch(resources)
    users = instances
    resources.each_key do |name|
      if provider = users.find { |user| user.name == name } # rubocop:disable Lint/AssignmentInCondition
        resources[name].provider = provider
      end
    end
  end

  def grant(user, table, privileges, options)
    user_string = self.class.cmd_user(user)
    priv_string = self.class.cmd_privs(privileges)
    table_string = privileges.include?('PROXY') ? self.class.cmd_user(table) : self.class.cmd_table(table)
    query = "GRANT #{priv_string}"
    query += " ON #{table_string}"
    query += " TO #{user_string}"
    query += self.class.cmd_options(options) unless options.nil?
    self.class.mysql_caller(query, 'system')
  end

  def create
    grant(@resource[:user], @resource[:table], @resource[:privileges], @resource[:options])

    @property_hash[:ensure]     = :present
    @property_hash[:table]      = @resource[:table]
    @property_hash[:user]       = @resource[:user]
    @property_hash[:options]    = @resource[:options] if @resource[:options]
    @property_hash[:privileges] = @resource[:privileges]

    exists? ? (return true) : (return false)
  end

  def revoke(user, table, revoke_privileges = ['ALL'])
    user_string = self.class.cmd_user(user)
    table_string = revoke_privileges.include?('PROXY') ? self.class.cmd_user(table) : self.class.cmd_table(table)
    priv_string = self.class.cmd_privs(revoke_privileges)
    # revoke grant option needs to be a extra query, because
    # "REVOKE ALL PRIVILEGES, GRANT OPTION [..]" is only valid mysql syntax
    # if no ON clause is used.
    # It hast to be executed before "REVOKE ALL [..]" since a GRANT has to
    # exist to be executed successfully
    if revoke_privileges.include?('ALL') && !revoke_privileges.include?('PROXY')
      query = "REVOKE GRANT OPTION ON #{table_string} FROM #{user_string}"
      self.class.mysql_caller(query, 'system')
    end
    query = "REVOKE #{priv_string} ON #{table_string} FROM #{user_string}"
    self.class.mysql_caller(query, 'system')
  end

  def destroy
    # if the user was dropped, it'll have been removed from the user hash
    # as the grants are already removed by the DROP statement
    if self.class.users.include? @property_hash[:user]
      if @property_hash[:privileges].include?('PROXY')
        revoke(@property_hash[:user], @property_hash[:table], @property_hash[:privileges])
      else
        revoke(@property_hash[:user], @property_hash[:table])
      end
    end
    @property_hash.clear

    exists? ? (return false) : (return true)
  end

  def exists?
    @property_hash[:ensure] == :present || false
  end

  def flush
    @property_hash.clear
    self.class.mysql_caller('FLUSH PRIVILEGES', 'regular')
  end

  mk_resource_methods

  def diff_privileges(privileges_old, privileges_new)
    diff = { revoke: [], grant: [] }
    if privileges_old.include? 'ALL'
      diff[:revoke] = privileges_old
      diff[:grant] = privileges_new
    elsif privileges_new.include? 'ALL'
      diff[:grant] = privileges_new
    else
      diff[:revoke] = privileges_old - privileges_new
      diff[:grant] = privileges_new - privileges_old
    end
    diff
  end

  def privileges=(privileges)
    diff = diff_privileges(@property_hash[:privileges], privileges)
    revoke(@property_hash[:user], @property_hash[:table], diff[:revoke]) unless diff[:revoke].empty?
    grant(@property_hash[:user], @property_hash[:table], diff[:grant], @property_hash[:options]) unless diff[:grant].empty?
    @property_hash[:privileges] = privileges
    self.privileges
  end

  def options=(options)
    revoke(@property_hash[:user], @property_hash[:table])
    grant(@property_hash[:user], @property_hash[:table], @property_hash[:privileges], options)
    @property_hash[:options] = options

    self.options
  end
end
