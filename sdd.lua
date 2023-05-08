local xml2lua = require('xml2lua')
local handler = require('xmlhandler.dom')
local parser = xml2lua.parser(handler)

-- BEGIN TEST
local json = require('json')
-- END TEST

-- BEGIN Configuration
local language = 'en'
-- END

-- BEGIN XML traversal and SDD processing utilities
local function get_children_of_name (node, name)
  local children = {}
  for _, child in ipairs(node._children) do
    if child._name == name then
      table.insert(children, child)
    end
  end
  return children
end

local function get_child_of_name (node, name)
  return get_children_of_name(node, name)[1]
end

local function get_text (node)
  local text = {}
  for _, child in ipairs(node._children) do
    if child._type == 'TEXT' then
      table.insert(text, child._text)
    elseif child._children ~= nil then
      table.insert(text, get_text(child))
    end
  end
  return table.concat(text, ' ')
end

local function get_child_with_language (children)
  for _, node in ipairs(children) do
    if node._attr == nil or language == nil then
      return node
    elseif node._attr['xml:lang'] == nil or node._attr['xml:lang'] == language then
      return node
    end
  end
end

local function get_label (node)
  local representation = get_child_of_name(node, 'Representation')
  local labels = get_children_of_name(representation, 'Label')
  return get_text(get_child_with_language(labels))
end
-- END

-- BEGIN Pandoc utilities
local function format_table_cell (content, attr)
  return pandoc.Cell(content, pandoc.AlignDefault, 1, 1, attr)
end
-- END

-- BEGIN Media objects
local function read_media_object (node)
  return {
    id = node._attr.id,
    type = get_text(get_child_of_name(node, 'Type')),
    source = get_child_of_name(node, 'Data')._attr.href,
    caption = get_label(node)
  }
end

local function format_media_object (media_object)
  if media_object.type == 'Image' then
    return pandoc.Figure(pandoc.Image({}, media_object.source), { media_object.caption }, { id = media_object.id })
  else
    return pandoc.Link(media_object.caption, media_object.source, { id = media_object.id })
  end
end
-- END

-- BEGIN Taxon names
local function read_taxon_name (node)
  local taxon_name = {
    id = node._attr.id,
    -- TODO multiple types of labels
    name = get_label(node),
    media_object_id = {}
    -- TODO canonical name, rank, etc.
  }
  for _, media_object in ipairs(get_children_of_name(get_child_of_name(node, 'Representation'), 'MediaObject')) do
    table.insert(taxon_name.media_object_id, media_object._attr.ref)
  end
  return taxon_name
end

local function format_taxon_name (taxon_name)
  return taxon_name.name
end
-- END

-- BEGIN Identification keys
local function read_identification_key (node)
  local key = {
    id = node._attr and node._attr.id or 0,
    title = get_label(node),
    -- description = ,
    steps = {}
  }

  local steps_by_parent = {}
  local leads_by_id = {}
  -- TODO question
  for _, choice in ipairs(get_child_of_name(node, 'Leads')._children) do
    if choice._type ~= 'ELEMENT' then
      goto continue
    end

    -- TODO get language
    local choice_data = {
      text = get_text(get_child_with_language(get_children_of_name(get_child_of_name(choice, 'Statement'), 'Label')))
    }
    if choice._name == 'Lead' then
      choice_data.id = choice._attr.id
      leads_by_id[choice_data.id] = choice_data
    else
      choice_data.result_id = get_child_of_name(choice, 'TaxonName')._attr.ref
    end

    local parent = get_child_of_name(choice, 'Parent')
    local parent_id = ''
    if parent ~= nil then
      parent_id = parent._attr.ref
    end
    if steps_by_parent[parent_id] == nil then
      local step = { parent_id = parent_id, choices = {} }
      table.insert(key.steps, step)
      steps_by_parent[parent_id] = step
    end
    table.insert(steps_by_parent[parent_id].choices, choice_data)

    ::continue::
  end

  for index, step in ipairs(key.steps) do
    step.index = index
    for _, choice in ipairs(step.choices) do
      choice.index = index
    end
    if step.parent_id ~= '' then
      leads_by_id[step.parent_id].next = index
      step.parent = leads_by_id[step.parent_id].index
    end
  end

  return key
end

local function format_identification_key (key, dataset)
  local list = {}
  for _, step in ipairs(key.steps) do
    local item = {
      pandoc.Span({}, { id = key.id .. '-' .. step.index })
    }
    for i, choice in ipairs(step.choices) do
      local item_part = {}

      if choice.text ~= nil then
        table.insert(item_part, choice.text)
      end

      -- TODO context taxa
      if choice.result_id ~= nil then
        table.insert(item_part, ' ')
        table.insert(item_part, pandoc.RawInline('tex', '\\mbox{'))
        table.insert(item_part, pandoc.Link(
          pandoc.Emph(format_taxon_name(
            dataset.taxon_names_by_id[choice.result_id],
            options
          )),
          '#' .. choice.result_id
        ))
      -- BEGIN TEST
        table.insert(item_part, pandoc.RawInline('tex', '} \\dotfill{} p.~\\pageref{key-10}'))
      -- END TEST
      end

      -- TODO subkeys
      if choice.next ~= nil then
        table.insert(item_part, ' ')
        table.insert(item_part, pandoc.RawInline('tex', '\\dotfill{} '))
        table.insert(item_part, pandoc.RawInline('html', '<span style="float: right; color: green;">'))
        table.insert(item_part, pandoc.Link(
          tostring(choice.next),
          '#' .. key.id .. '-' .. choice.next
        ))
        table.insert(item_part, pandoc.RawInline('html', '</span>'))
      end

      -- TODO media?

      if #item_part > 0 then
        table.insert(item_part, pandoc.LineBreak())
      end

      table.insert(item, pandoc.Para(item_part))
    end
    table.insert(list, item)
  end

  return {
    pandoc.Header(2, key.title, { id = key.id }),
    pandoc.OrderedList(list)
  }
end
-- END

local function read_dataset (node)
  -- Build indices
  local dataset = {
    -- Metadata
    title = get_label(node),

    -- Content sections
    keys = {},

    -- Support information
    media_by_id = {},
    taxon_names_by_id = {}
  }

  -- TODO check presence
  for _, node in ipairs(get_children_of_name(get_child_of_name(node, 'IdentificationKeys'), 'IdentificationKey')) do
    table.insert(dataset.keys, read_identification_key(node))
  end

  -- TODO check presence
  for _, node in ipairs(get_children_of_name(get_child_of_name(node, 'MediaObjects'), 'MediaObject')) do
    local media_object = read_media_object(node)
    dataset.media_by_id[media_object.id] = media_object
  end

  for index, node in ipairs(get_children_of_name(get_child_of_name(node, 'TaxonNames'), 'TaxonName')) do
    local taxon_name = read_taxon_name(node)
    taxon_name.index = index
    dataset.taxon_names_by_id[taxon_name.id] = taxon_name
  end

  -- TODO check presence
  for _, node in ipairs(get_children_of_name(get_child_of_name(node, 'NaturalLanguageDescriptions'), 'NaturalLanguageDescription')) do
    local description = {
      title = get_label(node),
      text = get_text(get_child_of_name(node, 'NaturalLanguageData'))
    }
    for _, ref_node in ipairs(get_children_of_name(get_child_of_name(node, 'Scope'), 'TaxonName')) do
      local taxon_name = dataset.taxon_names_by_id[ref_node._attr.ref]
      if taxon_name.descriptions == nil then taxon_name.descriptions = {} end
      table.insert(taxon_name.descriptions, description)
    end
  end

  return dataset
end

local function format_dataset (dataset)
  -- Format dataset output
  local blocks = {}

  -- Metadata
  if dataset.title ~= nil then
    table.insert(blocks, pandoc.Header(1, dataset.title))
  end

  -- TODO check if description?

  -- TODO checklist

  -- Identification keys
  for _, key in ipairs(dataset.keys) do
    for _, block in ipairs(format_identification_key(key, dataset)) do
      table.insert(blocks, block)
    end
  end

  -- Taxa
  -- TODO ordering
  table.insert(blocks, pandoc.Header(2, 'Taxonomy'))
  local taxon_names = {}
  for _, value in pairs(dataset.taxon_names_by_id) do table.insert(taxon_names, value) end
  table.sort(taxon_names, function (a, b)
    return a.index < b.index
  end)

  for _, taxon_name in ipairs(taxon_names) do
    table.insert(blocks, pandoc.Header(3, taxon_name.name, { id = taxon_name.id }))

    for _, media_object_id in ipairs(taxon_name.media_object_id) do
      -- TODO if not inserted already + check order
      table.insert(blocks, format_media_object(dataset.media_by_id[media_object_id]))
    end

    if taxon_name.descriptions ~= nil then
      for _, description in ipairs(taxon_name.descriptions) do
        local content = pandoc.read(description.text, 'html').blocks
        for _, block in ipairs(content) do
          table.insert(blocks, block)
        end
      end
    end
  end

  -- TODO species/sample descriptions + characters

  -- TODO bibliography

  return blocks
end

function Reader(input)
  parser:parse(tostring(input))
  local datasets = get_children_of_name(handler.root, 'Dataset')

  local blocks = {}
  table.insert(blocks, pandoc.RawInline('html', '<style>body{margin:0 auto;max-width:900px;font-family:sans-serif;}</style>'))
  for _, node in ipairs(datasets) do
    local dataset = read_dataset(node)
    for _, block in ipairs(format_dataset(dataset)) do
      table.insert(blocks, block)
    end
  end

  return pandoc.Pandoc(blocks)
end
