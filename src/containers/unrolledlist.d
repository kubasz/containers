/**
 * Unrolled Linked List.
 * Copyright: © 2014 Economic Modeling Specialists, Intl.
 * Authors: Brian Schott
 * License: $(LINK2 http://www.boost.org/LICENSE_1_0.txt Boost License 1.0)
 */

module containers.unrolledlist;

/**
 * Unrolled Linked List.
 *
 * Nodes are (by default) sized to fit within a 64-byte cache line. The number
 * of items stored per node can be read from the $(B nodeCapacity) field.
 * See_also: $(LINK http://en.wikipedia.org/wiki/Unrolled_linked_list)
 * Params:
 *     T = the element type
 *     supportGC = true to ensure that the GC scans the nodes of the unrolled
 *         list, false if you are sure that no references to GC-managed memory
 *         will be stored in this container.
 *     cacheLineSize = Nodes will be sized to fit within this number of bytes.
 */
struct UnrolledList(T, bool supportGC = true, size_t cacheLineSize = 64)
{
	private import std.traits;

	this(this) @disable;

	~this()
	{
		Node* prev = null;
		Node* cur = _front;
		while (cur !is null)
		{
			prev = cur;
			cur = cur.next;
			static if (!is(T == class))
				foreach (ref item; cur.items)
					typeid(T).destroy(&item);
			deallocateNode(prev);
		}
	}

	/**
	 * Inserts the given item into the end of the list.
	 */
	void insertBack(T item)
	{
		if (_back is null)
		{
			_back = allocateNode(item);
			_front = _back;
		}
		else
		{
			size_t index = _back.nextAvailableIndex();
			if (index >= nodeCapacity)
			{
				Node* n = allocateNode(item);
				_back.next = n;
				_back = n;
				index = 0;
			}
			else
			{
				_back.items[index] = item;
				_back.markUsed(index);
			}
		}
		_length++;
		assert (_back.registry <= fullBits!nodeCapacity);
	}

	/**
	 * Inserts the given range into the end of the list
	 */
	void insertBack(R)(R range)
	{
		foreach (ref r; range)
			insertBack(r);
	}

	/// ditto
	alias put = insertBack;
	/// ditto
	alias insert = insertBack;

	/**
	 * Inserts the given item in the frontmost available cell, which may put the
	 * item anywhere in the list as removal may leave gaps in list nodes. Use
	 * this only if the order of elements is not important.
	 */
	void insertAnywhere(T item)
	{
		Node* n = _front;
		while (_front !is null)
		{
			size_t i = n.nextAvailableIndex();
			if (i >= nodeCapacity)
			{
				if (n.next is null)
					break;
				n = n.next;
				continue;
			}
			n.items[i] = item;
			n.markUsed(i);
			_length++;
			assert (n.registry <= fullBits!nodeCapacity);
			return;
		}
		assert (n is _back);
		n = allocateNode(item);
		_back.next = n;
		_back = n;
		_length++;
		assert (_back.registry <= fullBits!nodeCapacity);
	}

	/// Returns: the length of the list
	size_t length() const nothrow pure @property
	{
		return _length;
	}

	/// Returns: true if the list is empty
	bool empty() const nothrow pure @property
	{
		return _length == 0;
	}

	/**
	 * Removes the given item from the list.
	 * Returns: true if something was removed.
	 */
	bool remove(T item)
	{
		import core.bitop;
		if (_front is null)
			return false;
		Node* n = _front;
		bool r = false;
		loop: while (n !is null)
		{
			foreach (i; 0 .. nodeCapacity)
			{
				if (n.items[i] == item)
				{
					n.markUnused(i);
					--_length;
					r = true;
					if (n.next !is null
						&& (popcnt(n.next.registry) + popcnt(n.registry) <= nodeCapacity))
					{
						mergeNodes(n, n.next);
					}
					break loop;
				}
			}
			n = n.next;
		}
		if (_front.registry == 0)
		{
			deallocateNode(_front);
			_front = null;
			_back = null;
		}
		return r;
	}

	/// Pops the front item off of the list
	void popFront()
	{
		moveFront();
		assert (_front is null || _front.registry != 0);
	}

	/// Pops the front item off of the list and returns it
	T moveFront()
	in
	{
		assert (!empty());
		assert (_front.registry != 0);
	}
	body
	{
		import std.stdio;
		import core.bitop;
		size_t index = bsf(_front.registry);
		T r = _front.items[index];
		_front.markUnused(index);
		_length--;
		if (_front.registry == 0)
		{
			auto f = _front;
			assert (_front.next !is _front);
			_front = _front.next;
			if (_front is null)
				_back = null;
			else
				assert (_front.registry <= fullBits!nodeCapacity);
			deallocateNode(f);
			return r;
		}
		if (_front.next !is null
			&& (popcnt(_front.next.registry) + popcnt(_front.registry) <= nodeCapacity))
		{
			mergeNodes(_front, _front.next);
		}
		return r;
	}

	invariant()
	{
		import std.string;
		assert (_front is null || _front.registry != 0, format("%x, %b", _front, _front.registry));
		assert (_front !is null || _back is null);
	}

	/// Returns: the item at the front of the list
	inout T front() const @property
	in
	{
		assert (!empty);
		assert (_front.registry != 0);
	}
	body
	{
		import core.bitop;
		import std.string;
		size_t index = bsf(_front.registry);
		assert (index < nodeCapacity, format("%d", index));
		return cast(T) _front.items[index];
	}

	/**
	 * Number of items stored per node.
	 */
	enum size_t nodeCapacity = fatNodeCapacity!(T.sizeof, 2, ushort, cacheLineSize);

	/// Returns: a range over the list
	Range range() const nothrow pure
	{
		return Range(_front);
	}

	/// ditto
	alias opSlice = range;

	static struct Range
	{
		@disable this();

		this(inout(Node)* current)
		{
			import core.bitop;
			this.current = current;
			if (current !is null)
			{
				index = bsf(current.registry);
				assert (index < nodeCapacity);
			}
		}

		T front() const @property
		{
			return cast(T) current.items[index];
		}

		void popFront() nothrow pure
		{
			index++;
			while (true)
			{
				if (current is null)
					return;
				if (index >= nodeCapacity)
				{
					current = current.next;
					index = 0;
				}
				else
				{
					if (current.isFree(index))
						index++;
					else
						return;
				}
			}
		}

		bool empty() const nothrow pure @property
		{
			return current is null;
		}

		Range save() const nothrow pure @property
		{
			return this;
		}

		const(Node)* current;
		size_t index;
	}

private:

	import std.allocator;
	import containers.internal.node;

	Node* _back;
	Node* _front;
	size_t _length;
//	uint refCount = 1;

	Node* allocateNode(T item)
	{
		Node* n = allocate!Node(Mallocator.it);
		static if (supportGC && shouldAddGCRange!T)
		{
			import core.memory;
			GC.addRange(n, Node.sizeof);
		}
		n.items[0] = item;
		n.markUsed(0);
		return n;
	}

	void deallocateNode(Node* n)
	{
		deallocate(Mallocator.it, n);
		static if (supportGC && shouldAddGCRange!T)
		{
			import core.memory;
			GC.removeRange(n);
		}
	}

	void mergeNodes(Node* first, Node* second)
	in
	{
		assert (first !is null);
		assert (second is first.next);
	}
	body
	{
		import core.bitop;
		size_t i;
		T[nodeCapacity] temp;
		foreach (j; 0 .. nodeCapacity)
			if (!first.isFree(j))
				temp[i++] = first.items[j];
		foreach (j; 0 .. nodeCapacity)
			if (!second.isFree(j))
				temp[i++] = second.items[j];
		first.next = second.next;
		first.items[0 .. i] = temp[0 .. i];
		first.registry = 0;
		foreach (k; 0 .. i)
			first.markUsed(k);
		assert (first.registry <= fullBits!nodeCapacity);
		static if (supportGC && shouldAddGCRange!T)
		{
			import core.memory;
			GC.removeRange(second);
			if (_back is second)
				_back = null;
		}
		deallocate(Mallocator.it, second);
	}

	static struct Node
	{
		size_t nextAvailableIndex() const nothrow pure
		{
			import core.bitop;
			return bsf(~registry);
		}

		void markUsed(size_t index) nothrow pure
		{
			registry |= (1 << index);
		}

		void markUnused(size_t index) nothrow pure
		{
			registry &= ~(1 << index);
			static if (shouldNullSlot!T)
				items[index] = null;
		}

		bool empty() const nothrow pure
		{
			return registry == 0;
		}

		bool isFree(size_t index) const nothrow pure
		{
			return (registry & (1 << index)) == 0;
		}

//		invariant()
//		{
//			import std.string;
//			assert (registry <= fullBits!nodeCapacity, format("%016b %016b", registry, fullBits!nodeCapacity));
//			assert (prev !is &this);
//			assert (next !is &this);
//		}

		ushort registry;
		T[nodeCapacity] items;
		Node* prev;
		Node* next;
	}
}

unittest
{
	import std.algorithm;
	import std.range;
	import std.stdio;
	import std.string;
	UnrolledList!int l;
	static assert (l.Node.sizeof <= 64);
	assert (l.empty);
	l.insert(0);
	assert (l.length == 1);
	assert (!l.empty);
	foreach (i; 1 .. 100)
		l.insert(i);
	assert (l.length == 100);
	assert (equal(l[], iota(100)));
	foreach (i; 0 .. 100)
		assert (l.remove(i), format("%d", i));
	assert (l.length == 0, format("%d", l.length));
	assert (l.empty);
	UnrolledList!int l2;
	l2.insert(1);
	l2.insert(2);
	l2.insert(3);
	assert (l2.front == 1);
	l2.popFront();
	assert (l2.front == 2);
	assert (equal(l2[], [2, 3]));
	l2.popFront();
	assert (equal(l2[], [3]));
	l2.popFront();
	assert (l2.empty, format("%d", l2.front));
	assert (equal(l2[], cast(int[]) []));
	UnrolledList!int l3;
	foreach (i; 0 .. 200)
		l3.insert(i);
	foreach (i; 0 .. 200)
	{
		auto x = l3.moveFront();
		assert (x == i, format("%d %d", i, x));
	}
	assert (l3.empty);
}
