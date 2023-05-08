local xml2lua = require('xml2lua')
local handler = require('xmlhandler.dom')
local parser = xml2lua.parser(handler)

-- BEGIN TEST
local json = require('json')
-- END TEST

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

local function get_label (node)
  local representation = get_child_of_name(node, 'Representation')
  if representation == nil then return nil end
  local label = get_child_of_name(representation, 'Label')
  if label == nil then return nil end
  return get_text(label)
end
-- END

-- BEGIN Pandoc utilities
local function format_header (level, content, id)
  if level >= 4 then
    return pandoc.Para({
      pandoc.Span({}, { id = id }),
      pandoc.Strong(content)
    })
  else
    return pandoc.Header(level, content, { id = id })
  end
end
-- END

-- BEGIN Media objects
local function read_media_object (node)
  local object = {
    id = node._attr.id,
    type = get_text(get_child_of_name(node, 'Type')),
    source = get_child_of_name(node, 'Source')._attr.href,
    caption = get_label(node)
  }

  local imageWidth = get_child_of_name(node, 'exif:PixelXDimension')
  object.width = imageWidth and get_text(imageWidth)

  return object
end

local function format_media_object (media_object)
  if media_object.type == 'Image' then
    return pandoc.Figure(
      pandoc.Image({}, media_object.source, nil, { width = media_object.width }),
      media_object.caption and { media_object.caption },
      { id = media_object.id }
    )
  else
    return pandoc.Link(media_object.caption, media_object.source, { id = media_object.id })
  end
end

local function format_media_objects (list, dataset)
  local blocks = {}
  for _, media_object_id in ipairs(list) do
    if dataset._state == nil or dataset._state.media[media_object_id] == nil then
      table.insert(blocks, format_media_object(dataset.media_by_id[media_object_id]))
      -- Media object has been included
      dataset._state.media[media_object_id] = true
    end
  end
  return pandoc.Blocks(blocks)
end
-- END

-- BEGIN Taxon names
local function read_taxon_name (node)
  local taxon_name = {
    id = node._attr.id,
    display_name = get_label(node),
    media_object_id = {}
  }

  local rank = get_child_of_name(node, 'Rank')
  if rank ~= nil then
    taxon_name.rank = rank._attr.literal
  end

  local canonicalName = get_child_of_name(node, 'CanonicalName')
  if canonicalName ~= nil then
    taxon_name.name = get_text(canonicalName)
  end

  local canonicalAuthorship = get_child_of_name(node, 'CanonicalAuthorship')
  if canonicalAuthorship ~= nil then
    taxon_name.authorship = get_text(canonicalAuthorship)
  end

  for _, media_object in ipairs(get_children_of_name(get_child_of_name(node, 'Representation'), 'MediaObject')) do
    table.insert(taxon_name.media_object_id, media_object._attr.ref)
  end
  return taxon_name
end

local function style_taxon_name (name, rank)
  if rank == 'genus' or rank == 'subgenus' or rank == 'species' or rank == 'subspecies' then
    return pandoc.Emph(name)
  else
    return name
  end
end

local function format_taxon_name (taxon_name, form)
  if form == nil or form == 'simple' then
    return { taxon_name.display_name }
  elseif form == 'vernacular' then
    if taxon_name.display_name == taxon_name.name then
      return {}
    end
    if taxon_name.authorship ~= nil and taxon_name.display_name == taxon_name.name .. ' ' .. taxon_name.authorship then
      return {}
    end
    return { taxon_name.display_name }
  elseif form == 'full' then
    if taxon_name.authorship ~= nil then
      return pandoc.Inlines({
        style_taxon_name(taxon_name.name, taxon_name.rank),
        ' ',
        taxon_name.authorship
      })
    elseif taxon_name.name ~= nil then
      return {
        style_taxon_name(taxon_name.name, taxon_name.rank)
      }
    else
      return { taxon_name.display_name }
    end
  elseif form == 'short' then
    if taxon_name.name ~= nil then
      return {
        style_taxon_name(
          string.gsub(taxon_name.name, '([A-Z])[A-Za-z0-9-]+ ', '%1. '),
          taxon_name.rank
        )
      }
    else
      return { taxon_name.display_name }
    end
  elseif form == 'long' then
    if taxon_name.name ~= nil then
      return {
        style_taxon_name(taxon_name.name, taxon_name.rank)
      }
    else
      return { taxon_name.display_name }
    end
  end
end
-- END

-- BEGIN Taxon hierarchy
local function read_taxon_tree (tree)
  local structure = {}
  local id_to_level = {}

  for _, node in ipairs(get_children_of_name(get_child_of_name(tree, 'Nodes'), 'Node')) do
    local id = node._attr and node._attr.id or nil
    local level = 0

    local parent = get_child_of_name(node, 'Parent')
    if parent ~= nil then
      level = id_to_level[parent._attr.ref] + 1
    end

    local synonym_id = {}
    local synonyms = get_child_of_name(node, 'Synonyms')
    if synonyms ~= nil then
      for _, synonym in ipairs(get_children_of_name(synonyms, 'TaxonName')) do
        table.insert(synonym_id, synonym._attr.ref)
      end
    end

    id_to_level[id] = level
    table.insert(structure, {
      level = level,
      taxon_name_id = get_child_of_name(node, 'TaxonName')._attr.ref,
      synonym_id = synonym_id
    })
  end

  return structure
end

local function make_taxon_tree (dataset)
  local taxon_names = {}

  for _, taxon_name in pairs(dataset.taxon_names_by_id) do
    table.insert(taxon_names, {
      level = 0,
      taxon_name_id = taxon_name.id,
      index = taxon_name.index,
      synonym_id = {}
    })
  end

  table.sort(taxon_names, function (a, b)
    return a.index < b.index
  end)

  return taxon_names
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

  local scope = get_child_of_name(node, 'Scope')
  if scope ~= nil then
    local nodes = get_children_of_name(scope, 'TaxonName')
    if #nodes > 0 then
      local taxon_name_ids = {}
      for _, node in ipairs(nodes) do
        table.insert(taxon_name_ids, node._attr.ref)
      end
      key.scope = taxon_name_ids
    end
  end

  local steps_by_parent = {}
  local leads_by_id = {}
  -- TODO question
  for _, choice in ipairs(get_child_of_name(node, 'Leads')._children) do
    if choice._type ~= 'ELEMENT' then
      goto continue
    end

    local choice_data = {
      text = get_text(get_child_of_name(choice, 'Statement'))
    }

    if choice._attr ~= nil and choice._attr.id ~= nil then
      choice_data.id = choice._attr.id
      leads_by_id[choice_data.id] = choice_data
    end

    local taxon = get_child_of_name(choice, 'TaxonName')
    if taxon ~= nil then
      choice_data.taxon_ref = taxon._attr.ref
    end

    local subkey = get_child_of_name(choice, 'Subkey')
    if subkey ~= nil then
      choice_data.subkey_ref = subkey._attr.ref
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

    for _, node in ipairs(get_children_of_name(choice, 'MediaObject')) do
      if choice_data.media_object_id == nil then
        choice_data.media_object_id = {}
      end
      table.insert(choice_data.media_object_id, node._attr.ref)
    end

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

      if choice.next ~= nil or choice.taxon_ref ~= nil or choice.subkey_ref ~= nil then
        table.insert(item_part, ' ')
        table.insert(item_part, pandoc.RawInline('tex', '\\dotfill{} '))
        table.insert(item_part, pandoc.RawInline('html', '<span style="float: right;">'))

        if choice.taxon_ref ~= nil then
          table.insert(item_part, pandoc.RawInline('tex', '\\mbox{'))
          table.insert(item_part, pandoc.Link(
            format_taxon_name(dataset.taxon_names_by_id[choice.taxon_ref], 'short'),
            '#' .. choice.taxon_ref
          ))
          table.insert(item_part, pandoc.RawInline('tex', '}'))
        end

        if choice.next ~= nil then
          table.insert(item_part, pandoc.Link(
            tostring(choice.next),
            '#' .. key.id .. '-' .. choice.next
          ))
        end

        if choice.taxon_ref == nil and choice.next == nil and choice.subkey_ref ~= nil then
          table.insert(item_part, pandoc.RawInline('tex', '\\iffalse'))
          table.insert(item_part, pandoc.Link('go', choice.subkey_ref))
          table.insert(item_part, pandoc.RawInline('tex', '\\fi'))

          -- TeX alternative (show page number)
          table.insert(item_part, pandoc.RawInline('tex', ' p.~\\pageref{' .. choice.subkey_ref .. '}'))
        end

        table.insert(item_part, pandoc.RawInline('html', '</span>'))
      end

      if #item_part > 0 then
        table.insert(item_part, pandoc.LineBreak())
      end

      table.insert(item, pandoc.Para(item_part))

      if choice.media_object_id ~= nil then
        for _, block in ipairs(format_media_objects(choice.media_object_id, dataset)) do
          table.insert(item, block)
        end
      end
    end

    table.insert(list, item)
  end

  return {
    pandoc.Header(6, key.title, { id = key.id }),
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
    taxon_tree = nil,

    -- Support information
    media_by_id = {},
    taxon_names_by_id = {},
    agents_by_id = {}
  }

  local taxon_names = get_child_of_name(node, 'TaxonNames')
  if taxon_names ~= nil then
    for index, node in ipairs(get_children_of_name(taxon_names, 'TaxonName')) do
      local taxon_name = read_taxon_name(node)
      taxon_name.index = index
      dataset.taxon_names_by_id[taxon_name.id] = taxon_name
    end
  end

  local taxon_trees = get_child_of_name(node, 'TaxonHierarchies')
  if taxon_trees ~= nil then
    -- Use the first taxon hierarchy that is provided
    dataset.taxon_tree = read_taxon_tree(get_child_of_name(taxon_trees, 'TaxonHierarchy'))
  else
    -- If no taxon hierarchy is provided, make one based on the literal list of taxa
    dataset.taxon_tree = make_taxon_tree(dataset)
  end

  local identification_keys = get_child_of_name(node, 'IdentificationKeys')
  if identification_keys ~= nil then
    for _, node in ipairs(get_children_of_name(identification_keys, 'IdentificationKey')) do
      local identification_key = read_identification_key(node)

      -- Check whether key has taxonomic scope
      if identification_key.scope ~= nil then
        -- If so, attach to the first taxon
        local taxon_name_id = identification_key.scope[1]
        local taxon_name = dataset.taxon_names_by_id[taxon_name_id]
        if taxon_name.keys == nil then
          taxon_name.keys = {}
        end
        table.insert(taxon_name.keys, identification_key)
      else
        -- If not, attach to dataset root
        table.insert(dataset.keys, identification_key)
      end
    end
  end

  local natural_language_descriptions = get_child_of_name(node, 'NaturalLanguageDescriptions')
  if natural_language_descriptions ~= nil then
    for _, node in ipairs(get_children_of_name(natural_language_descriptions, 'NaturalLanguageDescription')) do
      local description = {
        title = get_label(node),
        text = get_text(get_child_of_name(node, 'NaturalLanguageData'))
      }
      -- Attach description to all taxa in scope
      for _, ref_node in ipairs(get_children_of_name(get_child_of_name(node, 'Scope'), 'TaxonName')) do
        local taxon_name = dataset.taxon_names_by_id[ref_node._attr.ref]
        if taxon_name.descriptions == nil then taxon_name.descriptions = {} end
        table.insert(taxon_name.descriptions, description)
      end
    end
  end

  local media_objects = get_child_of_name(node, 'MediaObjects')
  if media_objects ~= nil then
    for _, node in ipairs(get_children_of_name(media_objects, 'MediaObject')) do
      local media_object = read_media_object(node)
      dataset.media_by_id[media_object.id] = media_object
    end
  end

  local agents = get_child_of_name(node, 'Agents')
  if agents ~= nil then
    for _, node in ipairs(get_children_of_name(agents, 'Agent')) do
      dataset.agents_by_id[node._attr.id] = get_label(node)
    end
  end

  local metadata = get_child_of_name(node, 'RevisionData')
  if metadata ~= nil then
    local creators = get_child_of_name(metadata, 'Creators')
    if creators ~= nil then
      dataset.author = {}
      for _, agent in ipairs(get_children_of_name(creators, 'Agent')) do
        table.insert(dataset.author, dataset.agents_by_id[agent._attr.ref])
      end
    end

    local created = get_child_of_name(metadata, 'DateCreated')
    if created ~= nil then
      dataset.date = get_text(created)
    end
  end

  return dataset
end

local function format_dataset (dataset)
  dataset._state = {
    media = {}
  }

  -- Format dataset output
  local blocks = {}

  -- TODO checklist

  -- Identification keys (without a taxonomic scope)
  for _, key in ipairs(dataset.keys) do
    for _, block in ipairs(format_identification_key(key, dataset)) do
      table.insert(blocks, block)
    end
  end

  -- Taxa
  table.insert(blocks, pandoc.Header(1, 'Taxonomy'))

  for _, taxon in ipairs(dataset.taxon_tree) do
    local taxon_name = dataset.taxon_names_by_id[taxon.taxon_name_id]

    -- Section header
    table.insert(blocks, format_header(
      2 + taxon.level,
      format_taxon_name(taxon_name, 'full'),
      taxon_name.id
    ))

    -- Show vernacular name (if different)
    local vernacular = format_taxon_name(taxon_name, 'vernacular')
    if vernacular ~= nil then
      table.insert(blocks, pandoc.Para(vernacular))
    end

    -- Show synonyms
    local synonyms = {}
    for _, synonym_id in ipairs(taxon.synonym_id) do
      local synonym_taxon_name = dataset.taxon_names_by_id[synonym_id]
      table.insert(synonyms, '= ')
      for _, node in ipairs(format_taxon_name(synonym_taxon_name, 'full')) do
        table.insert(synonyms, node)
      end
      table.insert(synonyms, pandoc.LineBreak())
    end
    if #synonyms > 0 then
      table.insert(blocks, pandoc.Para(synonyms))
    end

    -- Show media (images etc.)
    format_media_objects(taxon_name.media_object_id, dataset)

    -- Show natural language descriptions
    if taxon_name.descriptions ~= nil then
      for _, description in ipairs(taxon_name.descriptions) do
        local content = pandoc.read(description.text, 'html').blocks
        for _, block in ipairs(content) do
          table.insert(blocks, block)
        end
      end
    end

    -- Show keys
    if taxon_name.keys ~= nil then
      for _, key in ipairs(taxon_name.keys) do
        for _, block in ipairs(format_identification_key(key, dataset)) do
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
  local dataset = read_dataset(get_child_of_name(handler.root, 'Dataset'))

  local blocks = {}

  for _, block in ipairs(format_dataset(dataset)) do
    table.insert(blocks, block)
  end

  return pandoc.Pandoc(blocks, pandoc.Meta({
    title = dataset.title,
    author = dataset.author,
    date = dataset.date and string.gsub(dataset.date, 'T.*', '')
  }))
end
