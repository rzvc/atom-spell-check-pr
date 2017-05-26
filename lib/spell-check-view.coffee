_ = require 'underscore-plus'
{CompositeDisposable} = require 'atom'
SpellCheckTask = require './spell-check-task'

CorrectionsView = null

module.exports =
class SpellCheckView
  constructor: (@editor, @task, @spellCheckModule, @getInstance) ->
    @disposables = new CompositeDisposable
    @initializeMarkerLayer()
    @taskWrapper = new SpellCheckTask @task

    @correctMisspellingCommand = atom.commands.add atom.views.getView(@editor), 'spell-check-pr:correct-misspelling', =>
      if marker = @markerLayer.findMarkers({containsBufferPosition: @editor.getCursorBufferPosition()})[0]
        CorrectionsView ?= require './corrections-view'
        @correctionsView?.destroy()
        @correctionsView = new CorrectionsView(@editor, @getCorrections(marker), marker, this, @updateMisspellings)
        @correctionsView.attach()

    atom.views.getView(@editor).addEventListener 'contextmenu', @addContextMenuEntries

    @taskWrapper.onDidSpellCheck (misspellings) =>
      @destroyMarkers()
      @addMarkers(misspellings) if @buffer?

    @disposables.add @editor.onDidChangePath =>
      @subscribeToBuffer()

    @disposables.add @editor.onDidChangeGrammar =>
      @subscribeToBuffer()

    @disposables.add atom.config.onDidChange 'editor.fontSize', =>
      @subscribeToBuffer()

    @disposables.add atom.config.onDidChange 'spell-check-pr.grammars', =>
      @subscribeToBuffer()

    @subscribeToBuffer()

    @disposables.add @editor.onDidDestroy(@destroy.bind(this))

  initializeMarkerLayer: ->
    @markerLayer = @editor.addMarkerLayer({maintainHistory: false})
    @markerLayerDecoration = @editor.decorateMarkerLayer(@markerLayer, {
      type: 'highlight',
      class: 'spell-check-misspelling',
      deprecatedRegionClass: 'misspelling'
    })

  destroy: ->
    @unsubscribeFromBuffer()
    @disposables.dispose()
    @taskWrapper.terminate()
    @markerLayer.destroy()
    @markerLayerDecoration.destroy()
    @correctMisspellingCommand.dispose()
    @correctionsView?.destroy()
    @clearContextMenuEntries()

  unsubscribeFromBuffer: ->
    @destroyMarkers()

    if @buffer?
      @bufferDisposable.dispose()
      @buffer = null

  subscribeToBuffer: ->
    @unsubscribeFromBuffer()

    if @spellCheckCurrentGrammar()
      @buffer = @editor.getBuffer()
      @bufferDisposable = @buffer.onDidStopChanging => @updateMisspellings()
      @updateMisspellings()

  spellCheckCurrentGrammar: ->
    grammar = @editor.getGrammar().scopeName
    _.contains(atom.config.get('spell-check-pr.grammars'), grammar)

  destroyMarkers: ->
    @markerLayer.destroy()
    @markerLayerDecoration.destroy()
    @initializeMarkerLayer()

  addMarkers: (misspellings) ->
    scope_whitelist_full = atom.config.get('spell-check-pr.scopes')
    scope_whitelist = []
    single_whitelist = []
    scope_blacklist = atom.config.get('spell-check-pr.scopeBlacklist')
    
    for scope in scope_whitelist_full
      if scope[0] == '!'
        single_whitelist.push(scope.substring(1));
      else
        scope_whitelist.push(scope);
    
    for misspelling in misspellings
      # Make sure the mispelling is an actual mispelling and not just code.
      word = @editor.getTextInBufferRange(misspelling)
      
      if (word.match(/.[A-Z]|[-_]/))
        continue;
    
      # Find scopes for the text given at the starting position of the misspelling
      scopes_for_misspelling = @editor.scopeDescriptorForBufferPosition(misspelling[0]).getScopesArray()
    
      # Blacklist
      if scope_blacklist.length and _.intersection(scopes_for_misspelling, scope_blacklist).length > 0
        continue

      # Whitelist
      if scope_whitelist.length is 0 or _.intersection(scopes_for_misspelling, scope_whitelist).length > 0 or
      scopes_for_misspelling.length == 1 and _.intersection(scopes_for_misspelling, single_whitelist).length == 1
        @markerLayer.markBufferRange(misspelling, {invalidate: 'touch'})
    return
    

  updateMisspellings: ->
    # Task::start can throw errors atom/atom#3326
    try
      @taskWrapper.start @editor.buffer
    catch error
      console.warn('Error starting spell check task', error.stack ? error)

  getCorrections: (marker) ->
    # Build up the arguments object for this buffer and text.
    projectPath = null
    relativePath = null
    if @buffer?.file?.path
      [projectPath, relativePath] = atom.project.relativizePath(@buffer.file.path)
    args = {
      projectPath: projectPath,
      relativePath: relativePath
    }

    # Get the misspelled word and then request corrections.
    instance = @getInstance()
    misspelling = @editor.getTextInBufferRange marker.getBufferRange()
    instance.suggest args, misspelling

  addContextMenuEntries: (mouseEvent) =>
    @clearContextMenuEntries()
    # Get buffer position of the right click event. If the click happens outside
    # the boundaries of any text, the method defaults to the buffer position of
    # the last character in the editor.
    currentScreenPosition = atom.views.getView(@editor).component.screenPositionForMouseEvent mouseEvent
    currentBufferPosition = @editor.bufferPositionForScreenPosition(currentScreenPosition)

    # Check to see if the selected word is incorrect.
    if marker = @markerLayer.findMarkers({containsBufferPosition: currentBufferPosition})[0]
      corrections = @getCorrections(marker)
      if corrections.length > 0
        @spellCheckModule.contextMenuEntries.push({
          menuItem: atom.contextMenu.add({'atom-text-editor': [{type: 'separator'}]})
        })

        correctionIndex = 0
        for correction in corrections
          contextMenuEntry = {}
          # Register new command for correction.
          commandName = 'spell-check:correct-misspelling-' + correctionIndex
          contextMenuEntry.command = do (correction, contextMenuEntry) =>
            atom.commands.add atom.views.getView(@editor), commandName, =>
              @makeCorrection(correction, marker)
              @clearContextMenuEntries()

          # Add new menu item for correction.
          contextMenuEntry.menuItem = atom.contextMenu.add({
            'atom-text-editor': [{label: correction.label, command: commandName}]
          })
          @spellCheckModule.contextMenuEntries.push contextMenuEntry
          correctionIndex++

        @spellCheckModule.contextMenuEntries.push({
          menuItem: atom.contextMenu.add({'atom-text-editor': [{type: 'separator'}]})
        })

  makeCorrection: (correction, marker) =>
    if correction.isSuggestion
      # Update the buffer with the correction.
      @editor.setSelectedBufferRange(marker.getBufferRange())
      @editor.insertText(correction.suggestion)
    else
      # Build up the arguments object for this buffer and text.
      projectPath = null
      relativePath = null
      if @editor.buffer?.file?.path
        [projectPath, relativePath] = atom.project.relativizePath(@editor.buffer.file.path)
      args = {
        id: @id,
        projectPath: projectPath,
        relativePath: relativePath
      }

      # Send the "add" request to the plugin.
      correction.plugin.add args, correction

      # Update the buffer to handle the corrections.
      @updateMisspellings.bind(this)()

  clearContextMenuEntries: ->
    for entry in @spellCheckModule.contextMenuEntries
      entry.command?.dispose()
      entry.menuItem?.dispose()

    @spellCheckModule.contextMenuEntries = []
