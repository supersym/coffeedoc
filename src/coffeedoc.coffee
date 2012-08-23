###
Documentation functions
=======================

These functions extract relevant documentation info from AST nodes as returned
by the coffeescript parser.
###

getFullName = require(__dirname + '/helpers').getFullName


documentModule = (script, parser) ->
    ###
    Given a module's source code and an AST parser, returns module information
    in the form:

        {
            "docstring": "Module docstring",
            "classes": [class1, class1...],
            "functions": [func1, func2...]
        }

    AST parsers are defined in the `parsers.coffee` module
    ###
    nodes = parser.getNodes(script)
    first_obj = nodes[0]
    if first_obj?.type == 'Comment'
        docstring = formatDocstring(first_obj.comment)
    else
        docstring = null

    doc = {
        docstring: docstring
        deps: parser.getDependencies(nodes)
        classes: (documentClass(c) for c in parser.getClasses(nodes))
        functions: (documentFunction(f) for f in parser.getFunctions(nodes))
    }

    return doc


documentClass = (cls) ->
    ###
    Evaluates a class object as returned by the coffeescript parser, returning
    an object of the form:
    
        {
            "name": "MyClass",
            "docstring": "First comment following the class definition"
            "parent": "MySuperClass",
            "methods": [method1, method2...]
        }
    ###
    if cls.type == 'Assign'
        # Class assigned to variable -- ignore the variable definition
        cls = cls.value
    # Get docstring
    if cls.body.expressions.length <= 1
        firstObj = cls.body.expressions[0]?.base?.properties?[0]
    else
        firstObj = cls.body.expressions[0]
    if firstObj?.type == 'Comment'
        docstring = formatDocstring(firstObj.comment)
    else
        docstring = null

    # Get methods
    staticmethods = []
    instancemethods = []
    privatemethods = []
    for expr in cls.body.expressions
        if expr.type == 'Value'
            for method in (n for n in expr.base.objects \
                           when n.type == 'Assign' and n.value.type == 'Code')
                if method.variable.this
                    # Method attached to `this`, i.e. the constructor
                    staticmethods.push(method)
                else
                    # Method attached to prototype
                    if method.variable.base.value?.match /^_/
                        privatemethods.push(method)
                    else
                        instancemethods.push(method)
        else if expr.type == 'Assign' and expr.value.type == 'Code'
            # Static method
            if expr.variable.this # Only include public methods
                staticmethods.push(expr)

    if cls.parent?
        parent = getFullName(cls.parent)
    else
        parent = null

    doc = {
        name: getFullName(cls.variable)
        docstring: docstring
        parent: parent
        staticmethods: (documentFunction(m) for m in staticmethods)
        instancemethods: (documentFunction(m) for m in instancemethods)
        privatemethods: (documentFunction(m) for m in privatemethods) 
    }

    for method in doc.staticmethods
        method.name = method.name.replace(/^this\./, '')

    return doc


documentFunction = (func) ->
    ###
    Evaluates a function object as returned by the coffeescript parser,
    returning an object of the form:
    
        {
            "name": "myFunc",
            "docstring": "First comment following the function definition",
            "params": ["param1", "param2"...]
        }
    ###
    # Get docstring
    first_obj = func.value.body.expressions[0]
    if first_obj?.comment
        docstring = formatDocstring(first_obj.comment)
    else
        docstring = null

    # Get params
    if func.value.params
        params = for p in func.value.params
            if p.name.base?.value == 'this'
                '@' + p.name.properties[0].name.value
            else
                if p.splat then p.name.value + '...' else p.name.value

    else
        params = []

    # parse annotations
    annotations = null
    if docstring?
        lines = first_obj.comment.split("\n")
        
        inAnnotation = false
        indents = 0
        currentAnnotation = { name: '', value: '', raw: '' }
        
        for line in lines
            if inAnnotation
                if line.match(new RegExp("^\\s{#{ indents },#{ indents }}\\s+"))
                    currentAnnotation.value += ' '+line.replace(/^\s+/,'')
                    currentAnnotation.raw += line+'\n'
                else
                    inAnnotation = false
                    unless annotations?
                        annotations = {}
                    unless annotations[currentAnnotation.name]?
                        annotations[currentAnnotation.name] = []
                    annotations[currentAnnotation.name].push({value: currentAnnotation.value, rawValue: currentAnnotation.raw })
            
            if line.match(/^\s*[@]/)
                inAnnotation = true
                indents = 0
                while line.substring(0,1) isnt '@'
                    indents++
                    line = line.substring(1)
                
                currentAnnotation.name = line.substring(1,line.indexOf(' '))
                currentAnnotation.value = line.substring(line.indexOf(' ')+1)
                currentAnnotation.raw = line+'\n'
    
    doc = {
        name: getFullName(func.variable)
        docstring: docstring
        params: params
        annotations: annotations
        annotationFreeDocstring: (( formatDocstring, rawDocstring, annotations, markedAndFilterAnnotations... ) ->
            unless rawDocstring?
                return ''
            
            marked = null
            filterAnnotations = null
            
            if typeof(markedAndFilterAnnotations[0]) is 'function'
                marked = markedAndFilterAnnotations[0]
                if markedAndFilterAnnotations[1]?
                    filterAnnotations = markedAndFilterAnnotations[1]
            else
                filterAnnotations = markedAndFilterAnnotations[0]
            
            unless filterAnnotations?
                filterAnnotations = []
                filterAnnotations.push(key) for key of annotations
            
            docstring = rawDocstring
            for annotation in filterAnnotations
                if annotations[annotation]?
                    for occurence in annotations[annotation]
                        docstring = docstring.replace(occurence.rawValue,'')
            
            if marked?
                return marked(formatDocstring(docstring))
            
            formatDocstring(docstring)
        ).bind(null, formatDocstring, first_obj.comment, annotations)
    }


formatDocstring = (str) ->
    ###
    Given a string, returns it with leading whitespace removed but with
    indentation preserved. Replaces `\\#` with `#` to allow for the use of
    multiple `#` characters in markup languages (e.g. Markdown headers)
    ###
    lines = str.replace(/\\#/g, '#').split('\n')

    # Remove leading blank lines
    while /^\s*$/.test(lines[0])
        lines.shift()
    if lines.length == 0
        return null

    # Get least indented non-blank line
    indentation = for line in lines
        if /^\s*$/.test(line) then continue
        line.match(/^\s*/)[0].length
    indentation = Math.min(indentation...)

    leading_whitespace = new RegExp("^\\s{#{ indentation }}")
    return (line.replace(leading_whitespace, '') for line in lines).join('\n')


exports.documentModule = documentModule
