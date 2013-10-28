require 'set'
class ObjectGraph
  # Create a new ObjectGraph for the given object.
  #
  # @note Careful not to add any references to this object yourself.
  #
  # @example
  #   # good:
  #   ObjectGraph.new(controller.model_cache.first)
  #
  #   # bad: adds an extra reference
  #   model = controller.model_cache.first
  #   ObjectGraph.new(model)
  #
  def initialize(obj=nil, distance=nil)
    @obj = obj
    @distance = distance
  end

  # Get the list of edges in this graph.
  #
  # Each array in the set is a pair of two objects where the first object is
  # retaining the second object.
  #
  # @return Set<[Object, Object]>
  def edges
    @edges ||= calculate_edges_in_isolation
  end

  # Get the list of edges in this graph.
  #
  # Each array in the set is a pair of two objects and a string, the first
  # object retains the second, and the relationship is described by the string.
  #
  # @return Set<[Object,Object,String]>
  def annotated_edges
    edges.map do |(from, to)|
      [from, to, connection_reason(from, to)]
    end
  end

  # Get the source for this graph suitable for feeding into graphviz.
  #
  # @see #view!
  # @return [String]
  def graphviz
    str = "digraph G {\n"

    edges.flat_map{ |x| x }.uniq.each do |o|
      label = o.inspect.sub(/^(.{253})....+/){ $1 + "..." }.gsub(/.{64}/){ $& + "\n"}
      str << "#{o.__id__} [label=#{label.inspect}]\n"
    end

    annotated_edges.each do |(f,t,r)|
      if r
        str << "#{f.__id__} -> #{t.__id__} [label=#{r.inspect}]\n"
      else
        str << "#{f.__id__} -> #{t.__id__}\n"
      end
    end

    str << "}"
  end

  # Open a PDF view of the graph using graphviz.
  #
  # This method requires you have graphviz installed,
  # Please apt-get install graphviz, or brew install graphviz.
  #
  # @param [String] basename  The place to put the files needed to do this.
  def view!(basename="/tmp/object_graph")
    dot = basename + ".dot"; pdf = basename + ".pdf"
    File.write(dot, graphviz)
    `dot -Tpdf #{dot} >#{pdf}`
    `open #{pdf} || xdg-open #{pdf} || google-chrome #{pdf}`
  end

  private

  EXCLUDE_GLOBALS = [ :$FILENAME ]

  # Hack to ensure that global variables are marked in the output graph.
  def reset_globals
    ov = $VERBOSE
    $VERBOSE = nil
    @globals ||= Class.new(Hash){ def inspect; "globals"; end }.new
    @globals.replace({})
    global_variables.each do |x|
      @globals[x] = eval(x.to_s) if not EXCLUDE_GLOBALS.include?(x)
    end
  ensure
    $VERBOSE = ov
  end

  # Run the edge calculation on a separate thread so that we can tell
  # which Thread-references are caused by the algorithm and which
  # actually exist.
  def calculate_edges_in_isolation
    thread = Thread.new do
      GC.start
      reset_globals
      Thread.current[:edges] = traverse_reference_graph(@obj)
    end.join

    thread[:edges]
  end

  ToSee = Struct.new(:obj, :distance)

  # A breadth-first search of the reference graph of the given object.
  #
  # @return Set<Array<Object>>
  def traverse_reference_graph(obj)
    raise ArgumentError, "Cannot find references to nil or false" unless obj

    seen = [obj]
    to_see = [ ObjectGraph::ToSee.new(obj, 0) ]
    found = []

    edges = Set.new

    while obj_distance = to_see.shift
      obj, distance = obj_distance.obj, obj_distance.distance
      next if @distance and distance > @distance

      found.replace ObjectSpace.find_references(obj)
      found.each do |o|
        # Exclude the traversal algorithm and references from the source code from the graph.
        next if !(Object === o) || self.equal?(o) || found.equal?(o) || seen.equal?(o) || edges.include?(o) || Thread.current.equal?(o) || RubyVM::InstructionSequence === o || o.class == ObjectGraph::ToSee
        edges << [o, obj] unless obj.equal?(o)
        next if seen.include?(o)
        seen << o
        # Assume that named modules are GC roots.
        to_see << ObjectGraph::ToSee.new(o, distance + 1) unless Module === o && o.name
      end
    end

    edges
  end

  # A short string that identifies the reason that {to} was retained
  # by {from}.
  #
  # If no reason could be found, nil is returned.
  #
  # @param [Object] from
  # @param [Object] to
  # @return [String, nil]
  def connection_reason(from, to)
    if Object === from
      from.instance_variables.each do |x|
        return x.to_s if from.instance_variable_get(x).equal?(to)
      end
    end

    if Module === from
      from.class_variables.each do |x|
        return x.to_s if from.class_variable_get(x).equal?(to)
      end

      from.constants.each do |x|
        return "::#{x.to_s}" if !from.autoload?(x) && from.const_get(x).equal?(to)
      end

      if Proc === to
        from.send(:define_method, :__os_tmp, to)
        begin
          from.instance_methods.each do |x|
            if x != :__os_tmp && from.instance_method(x) == from.instance_method(:__os_tmp)
              return "#{x}()"
            end
          end
        ensure
          from.send(:undef_method, :__os_tmp) rescue nil
        end
      end
    end

    if $globals.equal?(from)
      from.each_pair do |k, v|
        return k.to_s if v.equal?(to)
      end
    end

    if Hash === from
      from.each_pair do |k, v|
        return "[#{k.inspect}]" if v.equal?(to)
        return "<key>" if k.equal?(to)
      end
    end

    if Array === from
      from.each.with_index do |v, k|
        return "[#{k.inspect}]" if v.equal?(to)
      end
    end
  end

end
