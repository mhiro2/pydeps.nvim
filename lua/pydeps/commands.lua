local audit = require("pydeps.commands.audit")
local info = require("pydeps.commands.info")
local provenance = require("pydeps.commands.provenance")
local resolve = require("pydeps.commands.resolve")
local toggle = require("pydeps.commands.toggle")
local tree = require("pydeps.commands.tree")
local update = require("pydeps.commands.update")

return {
  update = update.run,
  resolve = resolve.run,
  tree = tree.run,
  provenance = provenance.run,
  info = info.run,
  audit = audit.run,
  toggle = toggle.run,
}
