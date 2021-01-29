defmodule Ecto.Adapters.DynamoDB.Query do
  @moduledoc """
  Some query wrapper functions for helping us query dynamo db. Selects indexes to use, etc.
  Not to be confused with `Ecto.Query`.

  """

  import Ecto.Adapters.DynamoDB.Info
  import Ecto.Adapters.DynamoDB, only: [ecto_dynamo_log: 2]

  @typep key :: String.t
  @typep table_name :: String.t
  @typep query_op :: :== | :> | :< |:>= | :<= | :is_nil | :between | :begins_with | :in
  @typep boolean_op :: :and | :or
  @typep match_clause :: {term, query_op}
  @typep search_clause :: {key, match_clause} | {boolean_op, [search_clause]}
  @typep search :: [search_clause]
  @typep dynamo_response :: %{required(String.t) => term}

  # parameters for get_item:
  # TABLE_NAME::string,
  # [{LOGICAL_OP::atom, [{ATTRIBUTE::string, {VALUE::string, OPERATOR::atom}}]} | {ATTRIBUTE::string, {VALUE::string, OPERATOR::atom}}]
  #

  # Repo.all(model), provide cached results for tables designated in :cached_tables
  @spec get_item(table_name, search, keyword) :: dynamo_response | no_return
  def get_item(table, search, opts) when search == [], do: maybe_scan(table, search, opts)

  # Regular queries
  def get_item(table, search, opts) do
    t = :os.system_time(:millisecond)
    ecto_dynamo_log(:debug, "get_best_index!(table, search): #{inspect(get_best_index!(table, search))}")
    results = case get_best_index!(table, search) do
      # primary key based lookup uses the efficient 'get_item' operation
      {:primary, indexes} = index->
        #https://hexdocs.pm/ex_aws/ExAws.Dynamo.html#get_item/3
        # query = construct_search(index, search, opts)
        # TODO: fix this shit!
        {_, op} = deep_find_key(search, List.last(indexes))
        {hash_values, _} = deep_find_key(search, hd(indexes))

        # hash_values = List.wrap(hash_values)

        # if op == :in,
        #   do: ExAws.Dynamo.batch_get_item(construct_batch_get_item_query(table, indexes, hash_values, search, construct_opts(:get_item, opts))) |> ExAws.request!,
        #   else: ExAws.Dynamo.get_item(table, query, construct_opts(:get_item, opts)) |> ExAws.request!

        case op do
          :in ->
            ExAws.Dynamo.batch_get_item(construct_batch_get_item_query(table, indexes, hash_values, search, construct_opts(:get_item, opts))) |> ExAws.request!
          :== ->
            # query = construct_search(index, search, opts)
            ExAws.Dynamo.get_item(table, construct_search(index, search, opts), construct_opts(:get_item, opts)) |> ExAws.request!
          _ ->
            # TODO: fix and test this. Need to use range index when filter expression selected
            query = construct_search({nil, indexes}, search, opts)
            fetch_recursive(&ExAws.Dynamo.query/2, table, query, parse_recursive_option(:query, opts), %{})
        end

      # secondary index based lookups need the query functionality.
      index when is_tuple(index) ->
        # https://hexdocs.pm/ex_aws/ExAws.Dynamo.html#query/2
        query = construct_search(index, search, opts)
        fetch_recursive(&ExAws.Dynamo.query/2, table, query, parse_recursive_option(:query, opts), %{})

      :scan -> maybe_scan(table, search, opts)
    end
    ecto_dynamo_log(:debug, "GET ALL request (w/o filter) took: #{:os.system_time(:millisecond) - t}ms")


    filter(results, search)  # index may have had more fields than the index did, thus results need to be trimmed.
  end


  @doc """
  Returns an atom, :scan or :query, specifying whether the current search will be a DynamoDB scan or a query.
  """
  def scan_or_query?(table, search) do
    if get_best_index!(table, search) == :scan, do: :scan, else: :query
  end


  # we've a list of fields from an index that matches the (some of) the search fields,
  # so construct a dynamo db search criteria map with only the given fields and their
  # search objects!
  @spec construct_search({:primary | :primary_partial | nil | String.t, [String.t]}, search, keyword) :: keyword
  @spec construct_search({:secondary_partial, String.t, [String.t]}, search, keyword) :: keyword
  def construct_search({:primary, index_fields}, search, opts), do: construct_search(%{}, index_fields, search, opts)
  def construct_search({:primary_partial, index_fields}, search, opts) do
    # do not provide index_name for primary partial
    construct_search({nil, index_fields}, search, opts)
  end
  def construct_search({index_name, index_fields}, search, opts) do
    # Construct a DynamoDB FilterExpression (since it cannot be provided blank but may be,
    # we merge it with the full query)
    {filter_expression_tuple, expression_attribute_names, expression_attribute_values} = construct_filter_expression(search, index_fields)

    updated_ops = construct_opts(:query, opts)

    # :primary_partial might not provide an index name
    criteria = if index_name != nil, do: [index_name: index_name], else: []
    criteria ++ case index_fields do
      [hash, range] ->
        {hash_val, _op} = deep_find_key(search, hash)
        {range_expression, range_attribute_names, range_attribute_values} = construct_range_params(range, deep_find_key(search, range))
        [
          # We need ExpressionAttributeNames when field-names are reserved, for example "name" or "role"
          key_condition_expression: "##{hash} = :hash_key AND #{range_expression}",
          expression_attribute_names: Enum.reduce([%{"##{hash}" => hash}, range_attribute_names, expression_attribute_names], &Map.merge/2),
          expression_attribute_values: [hash_key: hash_val] ++ range_attribute_values ++ expression_attribute_values,
        ] ++ filter_expression_tuple ++ updated_ops

      [hash] ->
        {hash_val, _op} = deep_find_key(search, hash)
        [
          key_condition_expression: "##{hash} = :hash_key",
          expression_attribute_names: Map.merge(%{"##{hash}" => hash}, expression_attribute_names),
          expression_attribute_values: [hash_key: hash_val] ++ expression_attribute_values,
        ] ++ filter_expression_tuple ++ updated_ops

    end
  end

  def construct_search({:secondary_partial, index_name , index_fields}, search, opts) do
    construct_search({index_name, index_fields}, search, opts)
  end

  defp construct_search(criteria, [], _, _), do: criteria
  defp construct_search(criteria, [index_field|index_fields], search, opts) do
    Map.put(criteria, index_field, elem(deep_find_key(search, index_field), 0)) |> construct_search(index_fields, search, opts)
  end


  @spec construct_range_params(key, match_clause) :: {String.t, %{required(String.t) => key}, keyword()}
  defp construct_range_params(range, {[range_start, range_end], :between}) do
    {"##{range} between :range_start and :range_end", %{"##{range}" => range}, [range_start: range_start, range_end: range_end]}
  end
  defp construct_range_params(range, {prefix, :begins_with}) do
    {"begins_with(##{range}, :prefix)", %{"##{range}" => range}, [prefix: prefix]}
  end
  defp construct_range_params(range, {range_val, :==}) do
    {"##{range} = :range_key", %{"##{range}" => range}, [range_key: range_val]}
  end
  defp construct_range_params(range, {range_val, op}) when op in [:<, :>, :<=, :>=] do
    {"##{range} #{to_string(op)} :range_key", %{"##{range}" => range}, [range_key: range_val]}
  end


  @spec construct_opts(atom, keyword) :: keyword
  defp construct_opts(query_type, opts) do
    take_opts = case query_type do
      :get_item -> [:consistent_read]
      :query -> [:exclusive_start_key, :limit, :scan_index_forward, :consistent_read]
    end
    case opts[:projection_expression] do
      nil -> [select: opts[:select] || :all_attributes]
      _   -> Keyword.take(opts, [:projection_expression])
    end ++ Keyword.take(opts, take_opts)
  end


  # returns a tuple: {filter_expression_tuple, expression_attribute_names, expression_attribute_values}
  @spec construct_filter_expression(search, [String.t]) :: {[filter_expression: String.t], map, keyword}
  defp construct_filter_expression(search, index_fields) do
    # We can only construct a FilterExpression on attributes not in key-conditions.
    non_indexed_filters = collect_non_indexed_search(search, index_fields, [])

    case non_indexed_filters do
      [] -> {[], %{}, []}
      _  ->
        {filter_expression_list, expression_attribute_names, expression_attribute_values} =
          build_filter_expression_data(non_indexed_filters, {[], %{}, %{}})

        {[filter_expression: Enum.join(filter_expression_list, " and ")],
         expression_attribute_names,
         Enum.into(expression_attribute_values, [])}
    end
  end


  # Recursively strip out the fields for key-conditions; they could be mixed with non key-conditions.
  # TODO: this may be redundant - the indexed fields can just be skipped during the expression construction
  @spec collect_non_indexed_search(search, [String.t], search) :: search
  defp collect_non_indexed_search([], _index_fields, acc), do: acc
  defp collect_non_indexed_search([search_clause | search_clauses], index_fields, acc) do
    case search_clause do
      {field, {_val, _op}} = complete_tuple when not field in [:and, :or] ->
        if Enum.member?(index_fields, field),
        do: collect_non_indexed_search(search_clauses, index_fields, acc),
        else: collect_non_indexed_search(search_clauses, index_fields, [complete_tuple | acc])

      {logical_op, deeper_clauses} when logical_op in [:and, :or] ->
        filtered_clauses = collect_non_indexed_search(deeper_clauses, index_fields, [])
        # don't keep empty logical_op groups
        if filtered_clauses == [],
        do: collect_non_indexed_search(search_clauses, index_fields, acc),
        else: collect_non_indexed_search(search_clauses, index_fields, [{logical_op, filtered_clauses} | acc])
    end
  end

  # Recursively reconstruct parentheticals
  @type expression_data_acc :: {[String.t], map, map}
  @spec build_filter_expression_data(search, expression_data_acc) :: expression_data_acc
  defp build_filter_expression_data([], acc), do: acc
  defp build_filter_expression_data([expr | exprs], {filter_exprs, attr_names, attr_values}) do
    case expr do
      # a list of lookup fields; iterate.
      {field, {val, op} = val_op_tuple} = complete_tuple when is_tuple(val_op_tuple) ->
        updated_filter_exprs = [construct_conditional_statement(complete_tuple) | filter_exprs]
        updated_attr_names = Map.merge(%{"##{field}" => field}, attr_names)
        updated_attr_values = Map.merge(format_expression_attribute_value(field, val, op), attr_values)

        build_filter_expression_data(exprs, {updated_filter_exprs, updated_attr_names, updated_attr_values})

      {logical_op, exprs_list} when is_list(exprs_list) ->
        {deeper_filter_exprs, deeper_attr_names, deeper_attr_values} = build_filter_expression_data(exprs_list, {[], %{}, %{}})
        # We don't parenthesize only one expression
        updated_filter_exprs = case deeper_filter_exprs do
          [one_expression] ->
            [one_expression | filter_exprs]
          many_expressions  ->
            ["(" <> Enum.join(many_expressions, " #{to_string(logical_op)} ") <> ")" | filter_exprs]
        end
        updated_attr_names = Map.merge(deeper_attr_names, attr_names)
        updated_attr_values = Map.merge(deeper_attr_values, attr_values)

        build_filter_expression_data(exprs, {updated_filter_exprs, updated_attr_names, updated_attr_values})
    end
  end

  @spec format_expression_attribute_value(key, term, query_op | [query_op]) :: map
  defp format_expression_attribute_value(field, _val, :is_nil), do: %{String.to_atom(field <> "_val") => nil}
  defp format_expression_attribute_value(field, val, :in) do
    {result, _count} = Enum.reduce(val, {%{}, 1}, fn (v, {acc, count}) ->
      {Map.merge(acc, %{String.to_atom(field <> "_val#{to_string(count)}") => v}), count + 1}
    end)
    result
  end
  # double op
  defp format_expression_attribute_value(field, [val1, val2], [_op1, _op2]) do
    %{String.to_atom(field <> "_val1") => val1, String.to_atom(field <> "_val2") => val2}
  end
   defp format_expression_attribute_value(field, [start_val, end_val], :between) do
    %{String.to_atom(field <> "_start_val") => start_val, String.to_atom(field <> "_end_val") => end_val}
  end
  defp format_expression_attribute_value(field, val, _op), do: %{String.to_atom(field <> "_val") => val}


  # double op (neither of them ought be :==)
  @spec construct_conditional_statement({key, {term, query_op} | {[term], [query_op]}}) :: String.t
  defp construct_conditional_statement({field, {[_val1, _val2], [op1, op2]}}) do
    "##{field} #{to_string(op1)} :#{field <> "_val1"} and ##{field} #{to_string(op2)} :#{field <> "_val2"}"
  end
  defp construct_conditional_statement({field, {_val, :is_nil}}) do
    "(##{field} = :#{field <> "_val"} or attribute_not_exists(##{field}))"
  end
  defp construct_conditional_statement({field, {val, :in}}) do
    {result, _count} = Enum.reduce(val, {[], 1}, fn (_val, {acc, count}) ->
      {[":#{field}_val#{to_string(count)}" | acc], count + 1}
    end)
    "(##{field} in (#{Enum.join(result, ",")}))"
  end
  defp construct_conditional_statement({field, {_val, :==}}) do
    "##{field} = :#{field <> "_val"}"
  end
  defp construct_conditional_statement({field, {_val, op}}) when op in [:<, :>, :<=, :>=] do
    "##{field} #{to_string(op)} :#{field <> "_val"}"
  end
  defp construct_conditional_statement({field, {[_start_val, _end_val], :between}}) do
    "##{field} between :#{field <> "_start_val"} and :#{field <> "_end_val"}"
  end
  defp construct_conditional_statement({field, {_val, :begins_with}}) do
    "begins_with(##{field}, :#{field}_val)"
  end

  defp construct_batch_get_item_query(table, indexes, hash_values, search, opts) do
    take_opts = Keyword.take(opts, [:consistent_read, :projection_expression])
    keys = case indexes do
      [hash_key] ->
        Enum.map(hash_values, fn hash_value -> [{String.to_atom(hash_key), hash_value}] end)

      [hash_key, range_key] ->
        {range_values, :in} = deep_find_key(search, range_key)
        ecto_dynamo_log(:debug, "Construct BatchGetItem: #{inspect([range_values, search, range_key, hash_values])}")
        # zipped = Enum.zip(hash_values, range_values)
        zipped =
          hash_values
          |> Enum.map(fn v -> Enum.zip(List.duplicate(v, length(range_values)), range_values) end)
          |> :lists.concat
        Enum.map(zipped, fn {hash_value, range_value} ->
          [{String.to_atom(hash_key), hash_value}, {String.to_atom(range_key), range_value}]
        end)
    end

    %{table => [keys: keys] ++ take_opts}
  end


  # TODO: Given the search criteria, filter out other results that were caught in the
  # index read. TODO: Can we do this on the server side dynamo query instead?
  # see: http://docs.aws.amazon.com/amazondynamodb/latest/APIReference/API_Query.html#DDB-Query-request-FilterExpression
  # note, this doesn't save us read capacity, but DOES reduce the result set and parsing over the wire.
  @spec filter(dynamo_response, search) :: dynamo_response
  def filter(results, _search), do: results



  @doc """
  Given a map with a search criteria, finds the best index to search against it.
  Returns a tuple indicating whether it's a primary key index, or a secondary index.
  To query against a secondary index in Dynamo, we NEED to have it's index name,
  so secondary indexes are returned as a tuple with the field name, whilst
  the primary key uses the atom :primary to distinguish it.

    {:primary, [indexed_fields_list]} | {"index_name", [indexed_fields_list]}

  Exception if the index doesn't exist.
  """
  @spec get_best_index(table_name, search) :: :not_found | {:primary, [String.t]} | {:primary_partial, [String.t]} | {String.t, [String.t]}
  def get_best_index(tablename, search) do
    case get_matching_primary_index(tablename, search) do
      # if we found a primary index with hash+range match, it's probably the best index.
      {:primary, _} = index -> index

      # we've found a primary hash index, but lets check if there's a more specific
      # secondary index with hash+sort available...
      {:primary_partial, _primary_hash} = index ->
        case get_matching_secondary_index(tablename, search) do
          {_, [_, _]} = sec_index -> sec_index  # we've found a better, more specific index.
          _                       -> index      # :not_found, or any other hash? default back to the primary.
        end

      # no primary found, so try for a secondary.
      :not_found -> get_matching_secondary_index(tablename, search)
    end
  end


  @doc """
  Same as get_best_index, but refers to a scan option on failure
  """
  def get_best_index!(tablename, search) do
    case get_best_index(tablename, search) do
      :not_found -> :scan
      index      -> index
    end

  end


  @doc """
  Given a search criteria of 1 or more fields, we try find out if the primary key is a
  good match and can be used to forfill this search. Returns the tuple
    {:primary, [hash] | [hash, range]}
  or
    :not_found
  """
  def get_matching_primary_index(tablename, search) do
    primary_key = primary_key!(tablename)

    case match_index(primary_key, search) do
      # We found a full primary index
      {:primary, _} = index -> index

      # We might be able to use a range query for all results with
      # the hash part, such as all circle_member with a specific person_id (all a user's circles).
      :not_found             -> match_index_hash_part(primary_key, search)
    end
  end


  @doc """
  Given a keyword list containing search field, value and operator to search for (which may also be nested under logical operators, e.g., `[{"id", {"franko", :==}}]`, or `[{:and, [{"circle_id", {"123", :==}}, {"person_id", {"abc", :>}}]}`), will return the dynamo db index description that will help us match this search. return :not_found if no index is found.

  Returns a tuple of {"index_name", [ hash_key or hash,range_key]]} or :not_found
  TODO: Does not help with range queries. -> The match_index_hash_part function is
    beginning to address this.
  """
  def get_matching_secondary_index(tablename, search) do
    # For each index, see how well it matches the search criteria.
    indexes = secondary_indexes(tablename)
    find_best_match(indexes, search, :not_found)
  end


  defp find_best_match([], _search, best), do: best
  defp find_best_match([index|indexes], search, best) do
    case match_index(index, search) do
      {_, [_,_]} -> index   # Matching on both hash + sort makes this the best index (as well as we can tell)
      {_, [_]}   -> find_best_match(indexes, search, index)   # we have a candidate for best match, though it's a hash key only. Look for better.
      :not_found ->
        case match_index_hash_part(index, search) do
          :not_found    -> find_best_match(indexes, search, best)    # haven't found anything good, keep looking, retain our previous best match.
          index_partial -> find_best_match(indexes, search, index_partial)
        end
    end
  end


  # The parameter, 'search', is a map: %{field_name::string => {value::string, operator::atom}}
  defp match_index(index, search) do
    case index do
      {_, [hash, range]} ->
        # Part of the query could be a nil filter on an indexed attribute;
        # in that case, we need a check in addition to the key, so we check the operator.
        # Also, the hash part can only accept an :== operator.
        hash_key = deep_find_key(search, hash)
        range_key = deep_find_key(search, range)
        if hash_key != nil and elem(hash_key, 1) in [:==, :in]
        and range_key != nil and elem(range_key, 1) != :is_nil,
        do: index, else: :not_found

      {_, [hash]} ->
        hash_key = deep_find_key(search, hash)
        if hash_key != nil and elem(hash_key, 1) in [:==, :in],
        do: index, else: :not_found
    end
  end

  @spec match_index_hash_part({:primary, [key]}, search) :: {:primary_partial, [key]} | :not_found
  @spec match_index_hash_part({String.t, [key]}, search) :: {:secondary_partial, String.t, [key]} | :not_found
  defp match_index_hash_part(index, search) do
    case index do
      {:primary, [hash, _range]} ->
        hash_key = deep_find_key(search, hash)
        if hash_key != nil and elem(hash_key, 1) == :==,
        do: {:primary_partial, [hash]}, else: :not_found

      {index_name, [hash, _range]} ->
        hash_key = deep_find_key(search, hash)
        if hash_key != nil and elem(hash_key, 1) == :==,
        do: {:secondary_partial, index_name, [hash]}, else: :not_found

      _ -> :not_found
    end
  end

  # TODO: multiple use of deep_find_key could be avoided by using the recursion in the main module to provide a set of indexed attributes in addition to the nested logical clauses.
  @spec deep_find_key(search, key) :: nil | {term, query_op}
  defp deep_find_key([], _), do: nil
  defp deep_find_key([clause | clauses], key) do
    case clause do
      {field, {val, op}} when not field in [:and, :or] ->
        if field == key, do: {val, op}, else: deep_find_key(clauses, key)
      {logical_op, deeper_clauses} when logical_op in [:and, :or] ->
        found = deep_find_key(deeper_clauses, key)
        if found != nil, do: found, else: deep_find_key(clauses, key)
    end
  end

  @doc """
  Formats the recursive option according to whether the query is a DynamoDB scan or query. (The adapter defaults to recursive fetch in case of the latter but not the former)
  """
  def parse_recursive_option(scan_or_query, opts) do
    case opts[:page_limit] do
      page_limit when (is_integer page_limit) and page_limit > 0 ->
        page_limit

      page_limit when (is_integer page_limit) and page_limit < 1 ->
        raise ArgumentError, message: "#{inspect __MODULE__}.parse_recursive_option/2 error: :page_limit option must be greater than 0"

      _ when scan_or_query == :scan ->
        # scan defaults to no recursion, opts[:recursive] must equal true to enable it
        opts[:recursive] == true

      _ when scan_or_query == :query ->
        # query defaults to recursion, opts[:recursive] must equal false to disable it
        opts[:recursive] != false
    end
  end


  # scan
  defp maybe_scan(table, [], opts) do
    scan_enabled = opts[:scan] == true || Application.get_env(:ecto_adapters_dynamodb, :scan_all) == true || Enum.member?(Application.get_env(:ecto_adapters_dynamodb, :scan_tables), table)

    cond do
      # TODO: we could use the cached scan and apply the search filters
      # ourselves when they are provided.
      Enum.member?(Application.get_env(:ecto_adapters_dynamodb, :cached_tables), table) and opts[:scan] != true ->
        Ecto.Adapters.DynamoDB.Cache.scan!(table)

      scan_enabled ->
        limit_option = opts[:limit] || Application.get_env(:ecto_adapters_dynamodb, :scan_limit)
        scan_limit = if is_integer(limit_option), do: [limit: limit_option], else: []
        updated_opts = Keyword.drop(opts, [:recursive, :limit, :scan]) ++ scan_limit

        fetch_recursive(&ExAws.Dynamo.scan/2, table, updated_opts, parse_recursive_option(:scan, opts), %{})

      true ->
        maybe_scan_error(table)
    end
  end

  defp maybe_scan(table, search, opts) do
    scan_enabled = opts[:scan] == true || Application.get_env(:ecto_adapters_dynamodb, :scan_all) == true || Enum.member?(Application.get_env(:ecto_adapters_dynamodb, :scan_tables), table)

    limit_option = opts[:limit] || Application.get_env(:ecto_adapters_dynamodb, :scan_limit)
    scan_limit = if is_integer(limit_option), do: [limit: limit_option], else: []
    updated_opts = Keyword.drop(opts, [:recursive, :limit, :scan]) ++ scan_limit

    if scan_enabled do
      {filter_expression_tuple, expression_attribute_names, expression_attribute_values} = construct_filter_expression(search, [])

      expressions = [
        expression_attribute_names: expression_attribute_names,
        expression_attribute_values: expression_attribute_values
      ] ++ updated_opts ++ filter_expression_tuple

      fetch_recursive(&ExAws.Dynamo.scan/2, table, expressions, parse_recursive_option(:scan, opts), %{})
    else
      maybe_scan_error(table)
    end
  end

  @spec maybe_scan_error(table_name) :: no_return
  defp maybe_scan_error(table) do
    raise ArgumentError, message: "Scan option or configuration have not been specified, and could not confirm the table, #{inspect table}, as listed for scan or caching in the application's configuration. Please see README file for details."
  end

  @typep fetch_func :: (table_name, keyword -> ExAws.Operation.JSON.t)
  @spec fetch_recursive(fetch_func, table_name, keyword, boolean | number, map) :: dynamo_response
  defp fetch_recursive(func, table, expressions, recursive, result) do
    t = :os.system_time(:millisecond)
    updated_expressions = if recursive == true, do: Keyword.delete(expressions, :limit), else: expressions
    fetch_result = func.(table, updated_expressions) |> ExAws.request!
    ecto_dynamo_log(:debug, "GET ALL request (fetch recursive: fetch_result, request!) took: #{:os.system_time(:millisecond) - t}ms")
    # recursive can be a boolean or a page limit
    updated_recursive = update_recursive_option(recursive)

    if fetch_result["LastEvaluatedKey"] != nil and updated_recursive.continue do
      fetch_recursive(
        func,
        table,
        updated_expressions ++ [exclusive_start_key: fetch_result["LastEvaluatedKey"]],
        updated_recursive.new_value,
        combine_results(result, fetch_result)
      )
    else
      combine_results(result, fetch_result)
    end
  end

  @doc """
  Updates the recursive option during a recursive fetch, according to whether the option is a boolean or an integer (as in the case of page_limit)
  """
  def update_recursive_option(r) when (is_boolean r), do: %{continue: r,     new_value: r}
  def update_recursive_option(r) when (is_integer r), do: %{continue: r > 1, new_value: r - 1}

  @spec combine_results(map, map) :: map
  defp combine_results(result, scan_result) do
    if result == %{} do
      scan_result
    else
      %{"Count" => result_count, "Items" => result_items, "ScannedCount" => result_scanned_count} = result
      %{"Count" => scanned_count, "Items" => scanned_items, "ScannedCount" => scanned_scanned_count} = scan_result

      %{"Count" => result_count + scanned_count,
        "Items" => result_items ++ scanned_items,
        "ScannedCount" => result_scanned_count + scanned_scanned_count}
    end
  end

end
