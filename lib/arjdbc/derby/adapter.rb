ArJdbc.load_java_part :Derby

require 'arjdbc/util/table_copier'
require 'arjdbc/derby/schema_creation' # AR 4.x

module ArJdbc
  module Derby
    include Util::TableCopier

    def self.extended(adapter)
      require 'arjdbc/derby/active_record_patch'
    end

    def self.included(base)
      require 'arjdbc/derby/active_record_patch'
    end

    # @see ActiveRecord::ConnectionAdapters::JdbcAdapter#jdbc_connection_class
    def self.jdbc_connection_class
      ::ActiveRecord::ConnectionAdapters::DerbyJdbcConnection
    end

    # @see ActiveRecord::ConnectionAdapters::JdbcColumn#column_types
    def self.column_selector
      [ /derby/i, lambda { |config, column| column.extend(Column) } ]
    end

    # @note Part of this module is implemented in "native" Java.
    # @see ActiveRecord::ConnectionAdapters::JdbcColumn
    module Column

      private

      def extract_limit(sql_type)
        case @sql_type = sql_type.downcase
        when /^smallint/i    then @sql_type = 'smallint'; limit = 2
        when /^bigint/i      then @sql_type = 'bigint'; limit = 8
        when /^double/i      then @sql_type = 'double'; limit = 8 # DOUBLE PRECISION
        when /^real/i        then @sql_type = 'real'; limit = 4
        when /^integer/i     then @sql_type = 'integer'; limit = 4
        when /^datetime/i    then @sql_type = 'datetime'; limit = nil
        when /^timestamp/i   then @sql_type = 'timestamp'; limit = nil
        when /^time/i        then @sql_type = 'time'; limit = nil
        when /^date/i        then @sql_type = 'date'; limit = nil
        when /^xml/i         then @sql_type = 'xml'; limit = nil
        else
          limit = super
          # handle maximum length for a VARCHAR string :
          limit = 32672 if ! limit && @sql_type.index('varchar') == 0
        end
        limit
      end

      def simplified_type(field_type)
        case field_type
        when /^smallint/i    then :boolean
        when /^bigint|int/i  then :integer
        when /^real|double/i then :float
        when /^dec/i         then # DEC is a DECIMAL alias
          extract_scale(field_type) == 0 ? :integer : :decimal
        when /^timestamp/i   then :datetime
        when /^xml/i         then :xml
        when 'long varchar'  then :text
        when /for bit data/i then :binary
        # :name=>"long varchar for bit data", :limit=>32700
        # :name=>"varchar() for bit data", :limit=>32672
        # :name=>"char() for bit data", :limit=>254}
        else
          super
        end
      end

      # Post process default value from JDBC into a Rails-friendly format (columns{-internal})
      def default_value(value)
        # JDBC returns column default strings with actual single quotes around the value.
        return $1 if value =~ /^'(.*)'$/
        return nil if value == "GENERATED_BY_DEFAULT"
        value
      end

    end

    # @see ActiveRecord::ConnectionAdapters::Jdbc::ArelSupport
    def self.arel_visitor_type(config = nil)
      require 'arel/visitors/derby'; ::Arel::Visitors::Derby
    end

    ADAPTER_NAME = 'Derby'.freeze

    def adapter_name
      ADAPTER_NAME
    end

    # @private
    def init_connection(jdbc_connection)
      md = jdbc_connection.meta_data
      major_version = md.database_major_version; minor_version = md.database_minor_version
      if major_version < 10 || (major_version == 10 && minor_version < 5)
        raise ::ActiveRecord::ConnectionNotEstablished, "Derby adapter requires Derby >= 10.5"
      end
      if major_version == 10 && minor_version < 8 # 10.8 ~ supports JDBC 4.1
        config[:connection_alive_sql] ||=
          'SELECT 1 FROM SYS.SYSSCHEMAS FETCH FIRST 1 ROWS ONLY' # FROM clause mandatory
      else
        # NOTE: since the loaded Java driver class can't change :
        Derby.send(:remove_method, :init_connection) rescue nil
      end
    end

    def configure_connection
      # must be done or SELECT...FOR UPDATE won't work how we expect :
      tx_isolation = config[:transaction_isolation] # set false to leave as is
      tx_isolation = :serializable if tx_isolation.nil?
      @connection.transaction_isolation = tx_isolation if tx_isolation
      # if a user name was specified upon connection, the user's name is the
      # default schema for the connection, if a schema with that name exists
      set_schema(config[:schema]) if config.key?(:schema)
    end

    def index_name_length
      128
    end

    NATIVE_DATABASE_TYPES = {
      :primary_key => "int GENERATED BY DEFAULT AS identity NOT NULL PRIMARY KEY",
      :string => { :name => "varchar", :limit => 255 }, # 32672
      :text => { :name => "clob" }, # 2,147,483,647
      :char => { :name => "char", :limit => 254 }, # JDBC limit: 254
      :binary => { :name => "blob" }, # 2,147,483,647
      :float => { :name => "float", :limit => 8 }, # DOUBLE PRECISION
      :real => { :name => "real", :limit => 4 }, # JDBC limit: 23
      :double => { :name => "double", :limit => 8 }, # JDBC limit: 52
      :decimal => { :name => "decimal", :precision => 5, :scale => 0 }, # JDBC limit: 31
      :numeric => { :name => "decimal", :precision => 5, :scale => 0 }, # JDBC limit: 31
      :integer => { :name => "integer", :limit => 4 }, # JDBC limit: 10
      :smallint => { :name => "smallint", :limit => 2 }, # JDBC limit: 5
      :bigint => { :name => "bigint", :limit => 8 }, # JDBC limit: 19
      :date => { :name => "date" },
      :time => { :name => "time" },
      :datetime => { :name => "timestamp" },
      :timestamp => { :name => "timestamp" },
      :xml => { :name => "xml" },
      :boolean => { :name => "smallint", :limit => 1 }, # TODO boolean (since 10.7)
      :object => { :name => "object" },
    }

    # @override
    def native_database_types
      NATIVE_DATABASE_TYPES
    end

    # Ensure the savepoint name is unused before creating it.
    # @override
    def create_savepoint(name = current_savepoint_name(true))
      release_savepoint(name) if @connection.marked_savepoint_names.include?(name)
      super(name)
    end

    # @override
    def quote(value, column = nil)
      return value.quoted_id if value.respond_to?(:quoted_id)
      return value if sql_literal?(value)
      return 'NULL' if value.nil?

      column_type = column && column.type
      if column_type == :string || column_type == :text
        # Derby is not permissive
        # e.g. sending an Integer to a VARCHAR column will fail
        case value
        when BigDecimal then value = value.to_s('F')
        when Numeric then value = value.to_s
        when true, false then value = value.to_s
        when Date, Time then value = quoted_date(value)
        else # on 2.3 attribute serialization needs to_yaml here
          value = value.to_s if ActiveRecord::VERSION::MAJOR >= 3
        end
      end

      case value
      when String, ActiveSupport::Multibyte::Chars
        if column_type == :text
          "CAST('#{quote_string(value)}' AS CLOB)"
        elsif column_type == :binary
          "CAST(X'#{quote_binary(value)}' AS BLOB)"
        elsif column_type == :xml
          "XMLPARSE(DOCUMENT '#{quote_string(value)}' PRESERVE WHITESPACE)"
        elsif column_type == :integer
          value.to_i
        elsif column_type == :float
          value.to_f
        else
          "'#{quote_string(value)}'"
        end
      else
        super
      end
    end

    # @override
    def quoted_date(value)
      if value.acts_like?(:time) && value.respond_to?(:usec)
        usec = sprintf("%06d", value.usec)
        value = ::ActiveRecord::Base.default_timezone == :utc ? value.getutc : value.getlocal
        "#{value.strftime("%Y-%m-%d %H:%M:%S")}.#{usec}"
      else
        super
      end
    end if ::ActiveRecord::VERSION::MAJOR >= 3

    # @private In Derby, these cannot specify a limit.
    NO_LIMIT_TYPES = [ :integer, :boolean, :timestamp, :datetime, :date, :time ]

    # Convert the specified column type to a SQL string.
    # @override
    def type_to_sql(type, limit = nil, precision = nil, scale = nil)
      return super unless NO_LIMIT_TYPES.include?(t = type.to_s.downcase.to_sym)

      native_type = NATIVE_DATABASE_TYPES[t]
      native_type.is_a?(Hash) ? native_type[:name] : native_type
    end

    # @private
    class TableDefinition < ActiveRecord::ConnectionAdapters::TableDefinition

      def xml(*args)
        options = args.extract_options!
        column(args[0], 'xml', options)
      end

    end

    def table_definition(*args)
      new_table_definition(TableDefinition, *args)
    end

    # @override
    def empty_insert_statement_value
      'VALUES ( DEFAULT )' # won't work as Derby does need to know the columns count
    end

    # Set the sequence to the max value of the table's column.
    # @override
    def reset_sequence!(table, column, sequence = nil)
      mpk = select_value("SELECT MAX(#{quote_column_name(column)}) FROM #{quote_table_name(table)}")
      execute("ALTER TABLE #{quote_table_name(table)} ALTER COLUMN #{quote_column_name(column)} RESTART WITH #{mpk.to_i + 1}")
    end

    def reset_pk_sequence!(table, pk = nil, sequence = nil)
      klasses = classes_for_table_name(table)
      klass   = klasses.nil? ? nil : klasses.first
      pk      = klass.primary_key unless klass.nil?
      if pk && klass.columns_hash[pk].type == :integer
        reset_sequence!(klass.table_name, pk)
      end
    end

    def classes_for_table_name(table)
      ActiveRecord::Base.send(:subclasses).select { |klass| klass.table_name == table }
    end
    private :classes_for_table_name

    # @override
    def remove_index(table_name, options)
      execute "DROP INDEX #{index_name(table_name, options)}"
    end

    # @override
    def rename_table(name, new_name)
      execute "RENAME TABLE #{quote_table_name(name)} TO #{quote_table_name(new_name)}"
    end

    def add_column(table_name, column_name, type, options = {})
      add_column_sql = "ALTER TABLE #{quote_table_name(table_name)} ADD #{quote_column_name(column_name)} #{type_to_sql(type, options[:limit], options[:precision], options[:scale])}"
      add_column_options!(add_column_sql, options)
      execute(add_column_sql)
    end unless const_defined? :SchemaCreation

    # @override fix case where AR passes `:default => nil, :null => true`
    def add_column_options!(sql, options)
      options.delete(:default) if options.has_key?(:default) && options[:default].nil?
      sql << " DEFAULT #{quote(options.delete(:default))}" if options.has_key?(:default)
      super
    end unless const_defined? :SchemaCreation

    # @override
    def remove_column(table_name, *column_names)
      for column_name in column_names.flatten
        execute "ALTER TABLE #{quote_table_name(table_name)} DROP COLUMN #{quote_column_name(column_name)} RESTRICT"
      end
    end unless const_defined? :SchemaCreation

    # @override
    def change_column(table_name, column_name, type, options = {})
      # TODO this needs a review since now we're likely to be on >= 10.8

      # Notes about changing in Derby:
      #    http://db.apache.org/derby/docs/10.2/ref/rrefsqlj81859.html#rrefsqlj81859__rrefsqlj37860)
      #
      # We support changing columns using the strategy outlined in:
      #    https://issues.apache.org/jira/browse/DERBY-1515
      #
      # This feature has not made it into a formal release and is not in Java 6.
      # We will need to conditionally support this (supposed to arrive for 10.3.0.0).

      # null/not nulling is easy, handle that separately
      if options.include?(:null)
        # This seems to only work with 10.2 of Derby
        if options.delete(:null) == false
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NOT NULL"
        else
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN #{quote_column_name(column_name)} NULL"
        end
      end

      # anything left to do?
      unless options.empty?
        begin
          execute "ALTER TABLE #{quote_table_name(table_name)} ALTER COLUMN " <<
                  " #{quote_column_name(column_name)} SET DATA TYPE #{type_to_sql(type, options[:limit])}"
        rescue
          transaction do
            temp_new_column_name = "#{column_name}_newtype"
            # 1) ALTER TABLE t ADD COLUMN c1_newtype NEWTYPE;
            add_column table_name, temp_new_column_name, type, options
            # 2) UPDATE t SET c1_newtype = c1;
            execute "UPDATE #{quote_table_name(table_name)} SET " <<
                    " #{quote_column_name(temp_new_column_name)} = " <<
                    " CAST(#{quote_column_name(column_name)} AS #{type_to_sql(type, options[:limit])})"
            # 3) ALTER TABLE t DROP COLUMN c1;
            remove_column table_name, column_name
            # 4) ALTER TABLE t RENAME COLUMN c1_newtype to c1;
            rename_column table_name, temp_new_column_name, column_name
          end
        end
      end
    end

    # @override
    def rename_column(table_name, column_name, new_column_name)
      execute "RENAME COLUMN #{quote_table_name(table_name)}.#{quote_column_name(column_name)} " <<
              " TO #{quote_column_name(new_column_name)}"
    end

    # SELECT DISTINCT clause for a given set of columns and a given ORDER BY clause.
    #
    # Derby requires the ORDER BY columns in the select list for distinct queries, and
    # requires that the ORDER BY include the distinct column.
    # ```
    #   distinct("posts.id", "posts.created_at desc")
    # ```
    # @note This is based on distinct method for the PostgreSQL Adapter.
    # @override
    def distinct(columns, order_by)
      "DISTINCT #{columns_for_distinct(columns, order_by)}"
    end

    # @override Since AR 4.0 (on 4.1 {#distinct} is gone and won't be called).
    def columns_for_distinct(columns, orders)
      return columns if orders.blank?

      # construct a clean list of column names from the ORDER BY clause,
      # removing any ASC/DESC modifiers
      order_columns = [ orders ]; order_columns.flatten! # AR 3.x vs 4.x
      order_columns.map! do |column|
        column = column.to_sql unless column.is_a?(String) # handle AREL node
        column.split(',').collect! { |s| s.split.first }
      end.flatten!
      order_columns.reject!(&:blank?)
      order_columns = order_columns.zip (0...order_columns.size).to_a
      order_columns = order_columns.map { |s, i| "#{s} AS alias_#{i}" }

      columns = [ columns ]; columns.flatten!
      columns.push( *order_columns ).join(', ')
      # return a DISTINCT clause that's distinct on the columns we want but
      # includes all the required columns for the ORDER BY to work properly
    end

    # @override
    def primary_keys(table_name)
      @connection.primary_keys table_name.to_s.upcase
    end

    # @override
    def tables(name = nil)
      @connection.tables(nil, current_schema)
    end

    # @return [String] the current schema name
    def current_schema
      @current_schema ||=
        select_value "SELECT CURRENT SCHEMA FROM SYS.SYSSCHEMAS FETCH FIRST 1 ROWS ONLY", 'SCHEMA'
    end

    # Change the current (implicit) Derby schema to be used for this connection.
    def set_schema(schema)
      @current_schema = nil
      execute "SET SCHEMA #{schema}", 'SCHEMA'
    end
    alias_method :current_schema=, :set_schema

    # Creates a new Derby schema.
    # @see #set_schema
    def create_schema(schema)
      execute "CREATE SCHEMA #{schema}", 'Create Schema'
    end

    # Drops an existing schema, needs to be empty (no DB objects).
    def drop_schema(schema)
      execute "DROP SCHEMA #{schema} RESTRICT", 'Drop Schema'
    end

    # @private
    def recreate_database(name = nil, options = {})
      drop_database(name)
      create_database(name, options)
    end

    # @private
    def create_database(name = nil, options = {}); end

    # @private
    def drop_database(name = nil)
      tables.each { |table| drop_table(table) }
    end

    # @override
    def quote_column_name(name)
      %Q{"#{name.to_s.upcase.gsub('"', '""')}"}
    end

    # @override
    def quote_table_name_for_assignment(table, attr)
      quote_column_name(attr)
    end if ::ActiveRecord::VERSION::MAJOR > 3

    # @note Only used with (non-AREL) ActiveRecord **2.3**.
    # @see Arel::Visitors::Derby
    def add_limit_offset!(sql, options)
      sql << " OFFSET #{options[:offset]} ROWS" if options[:offset]
      # ROWS/ROW and FIRST/NEXT mean the same
      sql << " FETCH FIRST #{options[:limit]} ROWS ONLY" if options[:limit]
    end if ::ActiveRecord::VERSION::MAJOR < 3

    # @override
    def execute(sql, name = nil, binds = [])
      sql = to_sql(sql, binds)
      insert = self.class.insert?(sql)
      update = ! insert && ! self.class.select?(sql)
      sql = correct_is_null(sql, insert || update)
      super(sql, name, binds)
    end

    # Returns the value of an identity column of the last *INSERT* statement
    # made over this connection.
    # @note Check the *IDENTITY_VAL_LOCAL* function for documentation.
    # @return [Fixnum]
    def last_insert_id
      @connection.identity_val_local
    end

    private

    def correct_is_null(sql, insert_or_update = false)
      if insert_or_update
        if ( i = sql =~ /\sWHERE\s/im )
          where_part = sql[i..-1]; sql = sql.dup
          where_part.gsub!(/!=\s*NULL/i, 'IS NOT NULL')
          where_part.gsub!(/=\sNULL/i, 'IS NULL')
          sql[i..-1] = where_part
        end
        sql
      else
        sql.gsub(/=\sNULL/i, 'IS NULL')
      end
    end

    # NOTE: only setup query analysis on AR <= 3.0 since on 3.1 {#exec_query},
    # {#exec_insert} will be used for AR generated queries/inserts etc.
    # Also there's prepared statement support and {#execute} is meant to stay
    # as a way of running non-prepared SQL statements (returning raw results).
    if ActiveRecord::VERSION::MAJOR < 3 ||
      ( ActiveRecord::VERSION::MAJOR == 3 && ActiveRecord::VERSION::MINOR < 1 )

    def _execute(sql, name = nil)
      if self.class.insert?(sql)
        @connection.execute_insert(sql)
      elsif self.class.select?(sql)
        @connection.execute_query_raw(sql)
      else
        @connection.execute_update(sql)
      end
    end

    end

  end
end
