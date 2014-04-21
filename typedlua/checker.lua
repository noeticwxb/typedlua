--[[
This file implements the type checker for Typed Lua
]]

local scope = require "typedlua.scope"
local types = require "typedlua.types"

local lineno = scope.lineno
local begin_scope, end_scope = scope.begin_scope, scope.end_scope
local begin_function, end_function = scope.begin_function, scope.end_function

local Value = types.Value
local Any = types.Any
local Nil = types.Nil
local False = types.False
local True = types.True
local Boolean = types.Boolean
local Number = types.Number
local String = types.String

local checker = {}

local check_block, check_stm, check_exp

local function errormsg (env, pos)
  local l,c = lineno(env.subject, pos)
  return string.format("%s:%d:%d:", env.filename, l, c)
end

local function typeerror (env, msg, pos)
  local error_msg = "%s type error, %s"
  error_msg = string.format(error_msg, errormsg(env, pos), msg)
  table.insert(env.messages, error_msg)
end

local function warning (env, msg, pos)
  local error_msg = "%s warning, %s"
  error_msg = string.format(error_msg, errormsg(env, pos), msg)
  table.insert(env.messages, error_msg)
end

local function type2str (t)
  return types.tostring(t)
end

local function get_local (env, name)
  local scope = env.scope
  for s = scope, 0, -1 do
    if env[s]["local"][name] then
      return env[s]["local"][name]
    end
  end
  return nil
end

local function set_local (env, id, inferred_type, scope)
  local local_name, local_type, pos = id[1], id[2], id.pos
  if not local_type then
    if not inferred_type or types.isNil(inferred_type) then
      local_type = Any
    else
      local_type = types.supertypeof(inferred_type)
    end
  end
  if types.subtype(env["variable"], inferred_type, local_type) then
    id["type"] = local_type
  elseif types.consistent_subtype(env["variable"], inferred_type, local_type) then
    id["type"] = local_type
    local msg = "attempt to assign '%s' to '%s'"
    msg = string.format(msg, type2str(inferred_type), type2str(local_type))
    warning(env, msg, pos)
  else
    id["type"] = inferred_type
    local msg = "attempt to assign '%s' to '%s'"
    msg = string.format(msg, type2str(inferred_type), type2str(local_type))
    typeerror(env, msg, pos)
  end
  env[scope]["local"][local_name] = id
end

local function set_local_table (env, id, inferred_type, scope)
  local local_name, local_type, pos = id[1], id[2], id.pos
  local valid_assignent = false
  for i = 1, #local_type do
    local subtype_key, subtype_value = false, false
    for j = 1, #inferred_type do
      if types.subtype(env["variable"], inferred_type[j][1], local_type[i][1]) then
        subtype_key = true
        if types.subtype(env["variable"], inferred_type[j][2], local_type[i][2]) then
          subtype_value = true
        else
          subtype_value = false
          break
        end
      end
    end
    if (subtype_key and subtype_value) or
       (not subtype_key and types.isUnionNil(local_type[i][2])) then
      valid_assignment = true
    else
      valid_assignment = false
      break
    end
  end
  if not valid_assignment then
    id["type"] = inferred_type
    local msg = "attempt to assign '%s' to '%s'"
    msg = string.format(msg, type2str(inferred_type), type2str(local_type))
    typeerror(env, msg, pos)
  else
    id["type"] = local_type
  end
  env[scope]["local"][local_name] = id
end

local function set_type (node, t)
  node["type"] = t
end

local function infer_return_type (env, t)
  local fscope = env.fscope
  if not env["function"][env.fscope]["inferred_return_type"] then
    env["function"][env.fscope]["inferred_return_type"] = {}
  end
  local a = env["function"][env.fscope]["inferred_return_type"]
  a[#a + 1] = t
end

local function get_return_type (env)
  return env["function"][env.fscope]["return_type"]
end

local function set_return_type (env, t)
  env["function"][env.fscope]["return_type"] = t
end

local function set_vararg_type (env, t)
  env["function"][env.fscope]["vararg_type"] = t
end

local function check_explist (env, explist, top_level)
  for k, v in ipairs(explist) do
    check_exp(env, v, top_level)
  end
end

local function resize_tuple (t, n)
  local tuple = { tag = "Tuple" }
  local vararg = t[#t][1]
  for i = 1, #t - 1 do
    tuple[i] = t[i]
  end
  for i = #t, n - 1 do
    if types.isNil(vararg) then
      tuple[i] = vararg
    else
      tuple[i] = types.Union(vararg, Nil)
    end
  end
  tuple[n] = types.Vararg(vararg)
  return tuple
end

local function unionlist2tuple (t)
  local max = 1
  for i = 1, #t do
    if #t[i] > max then max = #t[i] end
  end
  local u = {}
  for i = 1, #t do
    if #t[i] < max then
      u[i] = resize_tuple(t[i], max)
    else
      u[i] = t[i]
    end
  end
  local l = {}
  for i = 1, #u do
    for j = 1, #u[i] do
      if not l[j] then l[j] = {} end
      table.insert(l[j], u[i][j])
    end
  end
  local n = { tag = "Tuple" }
  for i = 1, #l - 1 do
    n[i] = types.Union(table.unpack(l[i]))
  end
  local vs = {}
  for k, v in ipairs(l[#l]) do
    table.insert(vs, v[1])
  end
  n[#l] = types.Vararg(types.Union(table.unpack(vs)))
  return n
end

local function first_class (t)
  if types.isUnionlist(t) then
    return first_class(unionlist2tuple(t))
  elseif types.isTuple(t) then
    return first_class(t[1])
  elseif types.isVararg(t) then
    if types.isNil(t[1]) then
      return t[1]
    else
      return types.Union(t[1], Nil)
    end
  else
    return t
  end
end

local function explist2typelist (explist)
  local len = #explist
  if len == 0 then
    return types.Tuple(types.Vararg(Nil))
  else
    local typelist = { tag = "Tuple" }
    for i = 1, len - 1 do
      typelist[i] = first_class(explist[i]["type"])
    end
    local last_type = explist[len]["type"]
    if types.isUnionlist(last_type) then
      last_type = unionlist2tuple(last_type)
    end
    if types.isTuple(last_type) then
      for k, v in ipairs(last_type) do
        typelist[#typelist + 1] = v
      end
    else
      typelist[#typelist + 1] = last_type
    end
    if not types.isVararg(typelist[#typelist]) then
      typelist[#typelist + 1] = types.Vararg(Nil)
    end
    return typelist
  end
end

local function check_parameters (env, parlist)
  local t = types.Tuple()
  local vararg = types.Vararg(Value)
  local len = #parlist
  local is_vararg = false
  if len > 0 and parlist[len].tag == "Dots" then
    is_vararg = true
    len = len - 1
  end
  local i = 1
  while i <= len do
    local id = parlist[i]
    if not id[2] then id[2] = Any end
    set_local(env, id, id[2], env.scope)
    t[i] = id[2]
    i = i + 1
  end
  if not is_vararg then
    t[i] = vararg
  else
    local v = parlist[i]
    if not v[1] then v[1] = Any end
    vararg[1] = v[1]
    set_vararg_type(env, v[1])
  end
  t[i] = vararg
  return t
end

local function check_local (env, idlist, explist)
  check_explist(env, explist)
  local typelist = explist2typelist(explist)
  local last_type = typelist[#typelist]
  local fill_type = Nil
  if types.isVararg(last_type) and not types.isNil(last_type[1]) then
    fill_type = types.Union(last_type[1], Nil)
  end
  for k, v in ipairs(idlist) do
    local t = fill_type
    if typelist[k] then t = first_class(typelist[k]) end
    if v[2] and types.isVariable(v[2]) then
      v[2] = env["variable"][v[2][1]]
    end
    if v[2] and types.isTable(v[2]) and types.isTable(t) and explist[k].tag == "Table" then
      set_local_table(env, v, t, env.scope)
    else
      set_local(env, v, t, env.scope)
    end
  end
end

local function check_localrec (env, id, exp)
  local scope = env.scope
  begin_function(env)
  begin_scope(env)
  local idlist, typelist, block = exp[1], exp[2], exp[3]
  if not block then
    block = typelist
    typelist = types.Tuple(types.Vararg(Any))
  end
  local t1 = check_parameters(env, idlist)
  local t2 = typelist
  local t = types.Function(t1, t2)
  set_type(exp, t)
  id[2] = t
  set_local(env, id, t, scope)
  set_return_type(env, t2)
  check_block(env, block)
  end_scope(env)
  end_function(env)
end

local function check_dots (env, exp)
  local t = env["function"][env.fscope]["vararg_type"] or Nil
  set_type(exp, types.Vararg(t))
end

local function check_arith (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  local msg = "attempt to perform arithmetic on a '%s'"
  if types.subtype(env["variable"], t1, Number) and types.subtype(env["variable"], t2, Number) then
    set_type(exp, Number)
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1))
    warning(env, msg, exp1.pos)
  elseif types.isAny(t2) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t2))
    warning(env, msg, exp2.pos)
  else
    set_type(exp, Any)
    local wrong_type, wrong_pos = types.supertypeof(t1), exp1.pos
    if types.subtype(env["variable"], t1, Number) or types.isAny(t1) then
      wrong_type = types.supertypeof(t2)
      wrong_pos = exp2.pos
    end
    msg = string.format(msg, type2str(wrong_type))
    typeerror(env, msg, wrong_pos)
  end
end

local function check_concat (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  local msg = "attempt to concatenate a '%s'"
  if types.subtype(env["variable"], t1, String) and types.subtype(env["variable"], t2, String) then
    set_type(exp, String)
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1))
    warning(env, msg, exp1.pos)
  elseif types.isAny(t2) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t2))
    warning(env, msg, exp2.pos)
  else
    set_type(exp, Any)
    local wrong_type, wrong_pos = types.supertypeof(t1), exp1.pos
    if types.subtype(env["variable"], t1, String) or types.isAny(t1) then
      wrong_type = types.supertypeof(t2)
      wrong_pos = exp2.pos
    end
    msg = string.format(msg, type2str(wrong_type))
    typeerror(env, msg, wrong_pos)
  end
end

local function check_equal (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  set_type(exp, Boolean)
end

local function check_order (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  local msg = "attempt to compare '%s' with '%s'"
  if types.subtype(env["variable"], t1, Number) and types.subtype(env["variable"], t2, Number) then
    set_type(exp, Boolean)
  elseif types.subtype(env["variable"], t1, String) and types.subtype(env["variable"], t2, String) then
    set_type(exp, Boolean)
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1), types.supertypeof(t2))
    warning(env, msg, exp1.pos)
  elseif types.isAny(t2) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(types.supertypeof(t1)), type2str(t2))
    warning(env, msg, exp2.pos)
  else
    set_type(exp, Any)
    t1, t2 = types.supertypeof(t1), types.supertypeof(t2)
    msg = string.format(msg, type2str(t1), type2str(t2))
    typeerror(env, msg, exp.pos)
  end
end

local function check_and (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  if types.isNil(t1) or types.isFalse(t1) then
    set_type(exp, t1)
  else
    set_type(exp, types.Union(t1, t2))
  end
end

local function check_or (env, exp, top_level)
  local exp1, exp2 = exp[2], exp[3]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  if types.isNil(t1) or types.isFalse(t1) then
    set_type(exp, t2)
  elseif types.isUnionNil(t1) then
    set_type(exp, types.Union(types.UnionNoNil(t1), t2))
  else
    set_type(exp, types.Union(t1, t2))
  end
end

local function check_not (env, exp)
  local exp1 = exp[2]
  check_exp(env, exp1)
  set_type(exp, Boolean)
end

local function check_minus (env, exp)
  local exp1 = exp[2]
  check_exp(env, exp1)
  local t1 = exp1["type"]
  local msg = "attempt to perform arithmetic on a '%s'"
  if types.subtype(env["variable"], t1, Number) then
    set_type(exp, Number)
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1))
    warning(env, msg, exp1.pos)
  else
    set_type(exp, Any)
    msg = string.format(msg, type2str(types.supertypeof(t1)))
    typeerror(env, msg, exp1.pos)
  end
end

local function check_len (env, exp)
  local exp1 = exp[2]
  check_exp(env, exp1)
  local t1 = exp1["type"]
  local msg = "attempt to get length of a '%s' value"
  if types.subtype(env["variable"], t1, String) then
    set_type(exp, Number)
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1))
    warning(env, msg, exp1.pos)
  else
    set_type(exp, Any)
    msg = string.format(msg, type2str(types.supertypeof(t1)))
    typeerror(env, msg, exp1.pos)
  end
end

local function check_binary_op (env, exp, top_level)
  local op = exp[1]
  if op == "add" or op == "sub" or
     op == "mul" or op == "div" or op == "mod" or
     op == "pow" then
    check_arith(env, exp, top_level)
  elseif op == "concat" then
    check_concat(env, exp, top_level)
  elseif op == "eq" then
    check_equal(env, exp, top_level)
  elseif op == "lt" or op == "le" then
    check_order(env, exp, top_level)
  elseif op == "and" then
    check_and(env, exp, top_level)
  elseif op == "or" then
    check_or(env, exp, top_level)
  else
    error("expecting binary operator, but got " .. op)
  end
end

local function check_unary_op (env, exp, top_level)
  local op = exp[1]
  if op == "not" then
    check_not(env, exp, top_level)
  elseif op == "unm" then
    check_minus(env, exp, top_level)
  elseif op == "len" then
    check_len(env, exp, top_level)
  else
    error("expecting unary operator, but got " .. op)
  end
end

local function check_paren (env, exp, top_level)
  check_exp(env, exp[1], top_level)
  set_type(exp, exp[1]["type"])
end

local function check_id_read (env, exp, top_level)
  local name = exp[1]
  local local_var = get_local(env, name)
  if local_var then
    exp["type"] = local_var["type"]
  else
    local global = {}
    global.tag = "Index"
    global.pos = exp.pos
    global[1] = { tag = "Id", [1] = "_ENV", pos = exp.pos }
    global[2] = { tag = "String", [1] = name, pos = exp.pos }
    check_exp(env, global, top_level)
    set_type(exp, global["type"])
  end
end

local function check_index_read (env, exp, top_level)
  local exp1, exp2 = exp[1], exp[2]
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  local t1, t2 = exp1["type"], exp2["type"]
  local msg = "attempt to index '%s'"
  if types.isTable(t1) then
    local t
    for k, v in ipairs(t1) do
      if types.subtype(env["variable"], t2, v[1]) then
        t = v[2]
        break
      end
    end
    if t then
      set_type(exp, t)
    else
      set_type(exp, Nil)
      msg = msg .. " with '%s'"
      msg = string.format(msg, type2str(t1), type2str(t2))
      typeerror(env, msg, exp.pos)
    end
  elseif types.isAny(t1) then
    set_type(exp, Any)
    msg = string.format(msg, type2str(t1))
    warning(env, msg, exp.pos)
  else
    set_type(exp, Nil)
    msg = string.format(msg, type2str(t1))
    typeerror(env, msg, exp.pos)
  end
end

local function check_function (env, exp, top_level)
  begin_function(env)
  begin_scope(env)
  local idlist = exp[1]
  local t1 = check_parameters(env, idlist)
  local t2, block = exp[2], exp[3]
  if not block then
    block = t2
    t2 = types.Tuple(types.Vararg(Any))
  end
  set_type(exp, types.Function(t1, t2))
  if not top_level then
    set_return_type(env, t2)
    check_block(env, block)
  end
  end_scope(env)
  end_function(env)
end

local function check_fieldlist (env, exp, top_level)
  local t = { tag = "Table" }
  local i = 1
  for k, v in ipairs(exp) do
    local tag = v.tag
    t[k] = { tag = "Field" }
    if tag == "Pair" then
      check_exp(env, v[1], top_level)
      check_exp(env, v[2], top_level)
      t[k][1] = v[1]["type"]
      t[k][2] = types.supertypeof(v[2]["type"])
    else
      check_exp(env, v, top_level)
      t[k][1] = types.Literal(i)
      t[k][2] = types.supertypeof(v["type"])
      i = i + 1
    end
  end
  set_type(exp, t)
end

local function check_argument (env, name, t1, t2, i, pos)
  if types.subtype(env["variable"], t1, t2) then
  elseif types.consistent_subtype(env["variable"], t1, t2) then
    local msg = "parameter %d of %s, attempt to assign '%s' to '%s'"
    msg = string.format(msg, i, name, type2str(t1), type2str(t2))
    warning(env, msg, pos)
  else
    local msg = "parameter %d of %s, attempt to assign '%s' to '%s'"
    msg = string.format(msg, i, name, type2str(t1), type2str(t2))
    typeerror(env, msg, pos)
  end
end

local function check_arguments (env, name, t1, t2, pos)
  local len1, len2 = #t1, #t2
  if len1 < len2 then
    local i = 1
    while i < len1 do
      check_argument(env, name, t1[i], t2[i], i, pos)
      i = i + 1
    end
    local j = i
    while j <= len2 do
      check_argument(env, name, t1[i], t2[j], j, pos)
      j = j + 1
    end
  elseif len1 > len2 then
    local i = 1
    while i < len2 do
      check_argument(env, name, t1[i], t2[i], i, pos)
      i = i + 1
    end
    local j = i
    while j <= len1 do
      check_argument(env, name, t1[j], t2[i], i, pos)
      j = j + 1
    end
  else
    for k, v in ipairs(t1) do
      check_argument(env, name, t1[k], t2[k], k, pos)
    end
  end
end

local function var2name (var)
  local tag = var.tag
  if tag == "Id" then
    return var[1]
  elseif tag == "Index" then
    return " "
  end
end

local function check_call (env, exp, top_level)
  local exp1 = exp[1]
  local explist = {}
  check_exp(env, exp1, top_level)
  local name = var2name(exp1)
  for i = 2, #exp do
    explist[i - 1] = exp[i]
  end
  check_explist(env, explist, top_level)
  local typelist = explist2typelist(explist)
  local t = exp1["type"]
  if types.isFunction(t) then
    check_arguments(env, name, typelist, t[1], exp.pos)
    set_type(exp, t[2])
  elseif types.isAny(t) then
    local msg = "attempt to call %s of type 'any'"
    msg = string.format(msg, name)
    warning(env, msg, exp.pos)
    set_type(exp, Any)
  else
    local msg = "attempt to call %s of type '%s'"
    msg = string.format(msg, name, type2str(t))
    typeerror(env, msg, exp.pos)
    set_type(exp, Nil)
  end
end

local function check_invoke (env, exp, top_level)
  local exp1, exp2 = exp[1], exp[2]
  local explist = {}
  check_exp(env, exp1, top_level)
  check_exp(env, exp2, top_level)
  for i = 3, #exp do
    explist[i - 2] = exp[i]
  end
  check_explist(env, explist, top_level)
  local typelist = explist2typelist(explist)
  local t1, t2 = exp1["type"], exp2["type"]
  local msg = "attempt to index '%s'"
  if types.isTable(t1) then
    local t
    for k, v in ipairs(t1) do
      if types.subtype(env["variable"], t2, v[1]) then
        t = v[2]
        break
      end
    end
    if t then
      if types.isFunction(t) then
        check_arguments(env, exp2[1], typelist, t[1], exp.pos)
        set_type(exp, t[2])
      elseif types.isAny(t) then
        local msg = "attempt to call %s of type 'any'"
        msg = string.format(msg, exp2[1])
        warning(env, msg, exp.pos)
        set_type(exp, Any)
      else
        local msg = "attempt to call %s of type '%s'"
        msg = string.format(msg, exp2[1], type2str(t))
        typeerror(env, msg, exp.pos)
        set_type(exp, Nil)
      end
    else
      local msg = "cannot invoke undeclared method %s"
      msg = string.format(msg, exp2[1])
      typeerror(env, msg, exp.pos)
      set_type(exp, Nil)
    end
  elseif types.isAny(t1) then
    local msg = "attempt to index value of type 'any' to invoke method %s"
    msg = string.format(msg, exp2[1])
    warning(env, msg, exp.pos)
    set_type(exp, Any)
  else
    local msg = "attempt to index value of type '%s' to invoke method %s"
    msg = string.format(msg, type2str(t1), exp2[1])
    typeerror(env, msg, exp.pos)
    set_type(exp, Nil)
  end
end

function check_exp (env, exp, top_level)
  local tag = exp.tag
  if tag == "Nil" then
    set_type(exp, Nil)
  elseif tag == "Dots" then
    check_dots(env, exp)
  elseif tag == "True" then
    set_type(exp, True)
  elseif tag == "False" then
    set_type(exp, False)
  elseif tag == "Number" then -- `Number{ <number> }
    set_type(exp, types.Literal(exp[1]))
  elseif tag == "String" then -- `String{ <string> }
    set_type(exp, types.Literal(exp[1]))
  elseif tag == "Function" then -- `Function{ { ident* { `Dots type? }? } type? block }
    check_function(env, exp, top_level)
  elseif tag == "Table" then -- `Table{ ( `Pair{ expr expr } | expr )* }
    check_fieldlist(env, exp, top_level)
  elseif tag == "Op" then -- `Op{ opid expr expr? }
    if exp[3] then
      check_binary_op(env, exp, top_level)
    else
      check_unary_op(env, exp, top_level)
    end
  elseif tag == "Paren" then -- `Paren{ expr }
    check_paren(env, exp, top_level)
  elseif tag == "Call" then -- `Call{ expr expr* }
    check_call(env, exp, top_level)
  elseif tag == "Invoke" then -- `Invoke{ expr `String{ <string> } expr* }
    check_invoke(env, exp, top_level)
  elseif tag == "Id" then -- `Id{ <string> }
    check_id_read(env, exp, top_level)
  elseif tag == "Index" then -- `Index{ expr expr }
    check_index_read(env, exp, top_level)
  else
    error("cannot type check expression " .. tag)
  end
end

local function check_while (env, stm, top_level)
  check_exp(env, stm[1], top_level)
  check_block(env, stm[2], top_level)
end

local function check_repeat (env, stm, top_level)
  check_block(env, stm[1], top_level)
  check_exp(env, stm[2], top_level)
end

local function check_if (env, stm, top_level)
  for i = 1, #stm, 2 do
    local exp, block = stm[i], stm[i + 1]
    if block then
      check_exp(env, exp, top_level)
      check_block(env, block, top_level)
    else
      block = exp
      check_block(env, block, top_level)
    end
  end
end

local function check_fornum (env, stm, top_level)
  local id, exp1, exp2, exp3, block = stm[1], stm[2], stm[3], stm[4], stm[5]
  id[2] = Number
  begin_scope(env)
  set_local(env, id, Number, env.scope)
  check_exp(env, exp1, top_level)
  local t1 = exp1["type"]
  local msg = "'for' initial value must be a number"
  if types.subtype(env["variable"], t1, Number) then
  elseif types.consistent_subtype(env["variable"], t1, Number) then
    warning(env, msg, exp1.pos)
  else
    typeerror(env, msg, exp1.pos)
  end
  check_exp(env, exp2, top_level)
  local t2 = exp2["type"]
  local msg = "'for' limit must be a number"
  if types.subtype(env["variable"], t2, Number) then
  elseif types.consistent_subtype(env["variable"], t2, Number) then
    warning(env, msg, exp2.pos)
  else
    typeerror(env, msg, exp2.pos)
  end
  if block then
    check_exp(env, exp3, top_level)
    local t3 = exp3["type"]
    local msg = "'for' step must be a number"
    if types.subtype(env["variable"], t3, Number) then
    elseif types.consistent_subtype(env["variable"], t3, Number) then
      warning(env, msg, exp3.pos)
    else
      typeerror(env, msg, exp3.pos)
    end
    check_exp(env, exp3, top_level)
  else
    block = exp3
  end
  check_block(env, block, top_level)
  end_scope(env)
end

local function check_forin (env, idlist, explist, block)
  begin_scope(env)
  check_local(env, idlist, explist, top_level)
  check_block(env, block, top_level)
  end_scope(env)
end

local function check_var_assignment (env, var, inferred_type)
  local tag = var.tag
  if tag == "Id" then
    local name = var[1]
    local local_var = get_local(env, name)
    if local_var then
      local local_type = local_var["type"]
      if types.subtype(env["variable"], inferred_type, local_type) then
      elseif types.consistent_subtype(env["variable"], inferred_type, local_type) then
        local msg = "attempt to assign '%s' to '%s'"
        msg = string.format(msg, type2str(inferred_type), type2str(local_type))
        warning(env, msg, var.pos)
      else
        local msg = "attempt to assign '%s' to '%s'"
        msg = string.format(msg, type2str(inferred_type), type2str(local_type))
        typeerror(env, msg, var.pos)
      end
    else
      local global = {}
      global.tag = "Index"
      global.pos = var.pos
      global[1] = { tag = "Id", [1] = "_ENV", pos = var.pos }
      global[2] = { tag = "String", [1] = name, pos = var.pos }
      check_var_assignment(env, global, inferred_type)
    end
  elseif tag == "Index" then
    local exp1, exp2 = var[1], var[2]
    check_exp(env, exp1)
    check_exp(env, exp2)
    local t1, t2 = exp1["type"], exp2["type"]
    if types.isTable(t1) then
      local t
      for k, v in ipairs(t1) do
        if types.subtype(env["variable"], t2, v[1]) then
          t = v[2]
          break
        end
      end
      if t then
        if types.subtype(env["variable"], inferred_type, t) then
        elseif types.consistent_subtype(env["variable"], inferred_type, t) then
          local msg = "attempt to assign '%s' to '%s'"
          msg = string.format(msg, type2str(inferred_type), type2str(t))
          warning(env, msg, var.pos)
        else
          local msg = "attempt to assign '%s' to '%s'"
          msg = string.format(msg, type2str(inferred_type), type2str(t))
          typeerror(env, msg, var.pos)
        end
      else
        if t1.open then
          local f = { tag = "Field", [1] = t2, [2] = types.supertypeof(inferred_type) }
          t1[#t1 + 1] = f
        else
          local msg = "attempt to use '%s' to index closed table"
          msg = string.format(msg, type2str(t2))
          typeerror(env, msg, var.pos)
        end
      end
    elseif types.isAny(t1) then
      local msg = "attempt to index value of type 'any'"
      warning(env, msg, var.pos)
    else
      local msg = "attempt to index value of type '%s'"
      msg = string.format(msg, type2str(t1))
      typeerror(env, msg, var.pos)
    end
  end
end

local function check_assignment (env, varlist, explist, top_level)
  check_explist(env, explist, top_level)
  local typelist = explist2typelist(explist)
  local last_type = typelist[#typelist]
  local fill_type = Nil
  if types.isVararg(last_type) and not types.isNil(last_type[1]) then
    fill_type = types.Union(last_type[1], Nil)
  end
  for k, v in ipairs(varlist) do
    local t = fill_type
    if typelist[k] then t = first_class(typelist[k]) end
    check_var_assignment(env, v, t)
  end
end

local function check_return (env, stm, top_level)
  check_explist(env, stm, top_level)
  local typelist = explist2typelist(stm)
  infer_return_type(env, types.supertypeof(typelist))
  local t = get_return_type(env)
  local msg = "return type '%s' does not match '%s'"
  if types.subtype(env["variable"], typelist, t) then
  elseif types.consistent_subtype(env["variable"], typelist, t) then
    msg = string.format(msg, type2str(typelist), type2str(t))
    warning(env, msg, stm.pos)
  else
    msg = string.format(msg, type2str(typelist), type2str(t))
    typeerror(env, msg, stm.pos)
  end
end

local function check_interface (env, stm, top_level)
  local t = types.Table()
  if not top_level then
    for i = 2, #stm do
      local f = { tag = "Field" }
      f[1] = types.Literal(stm[i][1])
      f[2] = stm[i][2]
      t[#t + 1] = f
    end
  end
  local x = stm[1]
  env["variable"][x] = t
end

function check_stm (env, stm, top_level)
  local tag = stm.tag
  if tag == "Do" then -- `Do{ stat* }
    check_block(env, stm, top_level)
  elseif tag == "Set" then -- `Set{ {lhs+} {expr+} }
    check_assignment(env, stm[1], stm[2], top_level)
  elseif tag == "While" then -- `While{ expr block }
    check_while(env, stm, top_level)
  elseif tag == "Repeat" then -- `Repeat{ block expr }
    check_repeat(env, stm, top_level)
  elseif tag == "If" then -- `If{ (expr block)+ block? }
    check_if(env, stm, top_level)
  elseif tag == "Fornum" then -- `Fornum{ ident expr expr expr? block }
    check_fornum(env, stm, top_level)
  elseif tag == "Forin" then -- `Forin{ {ident+} {expr+} block }
    check_forin(env, stm[1], stm[2], stm[3], top_level)
  elseif tag == "Local" then -- `Local{ {ident+} {expr+}? }
    check_local(env, stm[1], stm[2], top_level)
  elseif tag == "Localrec" then -- `Localrec{ ident expr }
    check_localrec(env, stm[1][1], stm[2][1], top_level)
  elseif tag == "Goto" then -- `Goto{ <string> }
  elseif tag == "Label" then -- `Label{ <string> }
  elseif tag == "Return" then -- `Return{ <expr>* }
    check_return(env, stm, top_level)
  elseif tag == "Break" then
  elseif tag == "Call" then -- `Call{ expr expr* }
    check_call(env, stm, top_level)
  elseif tag == "Invoke" then -- `Invoke{ expr `String{ <string> } expr* }
    check_invoke(env, stm, top_level)
  elseif tag == "Interface" then -- `Interface{ <string> { <string> type }+ }
    check_interface(env, stm, top_level)
  else
    error("cannot type check statement " .. tag)
  end
end

function check_block (env, block, top_level)
  begin_scope(env)
  if not top_level then
    for k, v in ipairs(block) do
      check_stm(env, v, top_level)
    end
  end
  end_scope(env)
end

local function new_env (subject, filename)
  local env = {}
  env.subject = subject -- stores the subject for error messages
  env.filename = filename -- stores the filename for error messages
  env["function"] = {} -- stores function attributes
  env["variable"] = {} -- stores type variables
  env.messages = {} -- stores errors and warnings
  return env
end

function checker.typecheck (ast, subject, filename)
  assert(type(ast) == "table")
  assert(type(subject) == "string")
  assert(type(filename) == "string")
  local env = new_env(subject, filename)
  local ENV = { tag = "Id", [1] = "_ENV", [2] = types.Table() }
  ENV[2].open = true
  begin_function(env)
  begin_scope(env)
  set_vararg_type(env, String)
  set_return_type(env, types.Tuple(types.Vararg(Any)))
  set_local(env, ENV, ENV[2], env.scope)
--[[
  for k, v in ipairs(ast) do
    check_stm(env, v, true)
  end
  if #env.messages > 0 then
    end_scope(env)
    end_function(env)
    return ast, table.concat(env.messages, "\n")
  end
  ENV[2].open = false
]]
  for k, v in ipairs(ast) do
    check_stm(env, v, false)
  end
  end_scope(env)
  end_function(env)
  if #env.messages > 0 then
    return ast, table.concat(env.messages, "\n")
  else
    return ast
  end
end

return checker
