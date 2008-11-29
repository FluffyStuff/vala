/* valaobjectcreationexpression.vala
 *
 * Copyright (C) 2006-2008  Jürg Billeter
 *
 * This library is free software; you can redistribute it and/or
 * modify it under the terms of the GNU Lesser General Public
 * License as published by the Free Software Foundation; either
 * version 2.1 of the License, or (at your option) any later version.

 * This library is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 * Lesser General Public License for more details.

 * You should have received a copy of the GNU Lesser General Public
 * License along with this library; if not, write to the Free Software
 * Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301  USA
 *
 * Author:
 * 	Jürg Billeter <j@bitron.ch>
 */

using GLib;
using Gee;

/**
 * Represents an object creation expression in the source code.
 */
public class Vala.ObjectCreationExpression : Expression {
	/**
	 * The object type to create.
	 */
	public DataType type_reference {
		get { return _data_type; }
		set {
			_data_type = value;
			_data_type.parent_node = this;
		}
	}

	/**
	 * The construction method to use. May be null to indicate that
	 * the default construction method should be used.
	 */
	public Method constructor { get; set; }

	/**
	 * The construction method to use or the data type to be created
	 * with the default construction method.
	 */
	public MemberAccess member_name { get; set; }

	public bool struct_creation { get; set; }

	private Gee.List<Expression> argument_list = new ArrayList<Expression> ();

	private Gee.List<MemberInitializer> object_initializer = new ArrayList<MemberInitializer> ();

	private DataType _data_type;

	/**
	 * Creates a new object creation expression.
	 *
	 * @param member_name      object type to create
	 * @param source_reference reference to source code
	 * @return                 newly created object creation expression
	 */
	public ObjectCreationExpression (MemberAccess member_name, SourceReference source_reference) {
		this.source_reference = source_reference;
		this.member_name = member_name;
	}
	
	/**
	 * Appends the specified expression to the list of arguments.
	 *
	 * @param arg an argument
	 */
	public void add_argument (Expression arg) {
		argument_list.add (arg);
		arg.parent_node = this;
	}

	/**
	 * Returns a copy of the argument list.
	 *
	 * @return argument list
	 */
	public Gee.List<Expression> get_argument_list () {
		return new ReadOnlyList<Expression> (argument_list);
	}

	/**
	 * Appends the specified member initializer to the object initializer.
	 *
	 * @param init a member initializer
	 */
	public void add_member_initializer (MemberInitializer init) {
		object_initializer.add (init);
		init.parent_node = this;
	}

	/**
	 * Returns the object initializer.
	 *
	 * @return member initializer list
	 */
	public Gee.List<MemberInitializer> get_object_initializer () {
		return new ReadOnlyList<MemberInitializer> (object_initializer);
	}

	public override void accept (CodeVisitor visitor) {
		visitor.visit_object_creation_expression (this);

		visitor.visit_expression (this);
	}

	public override void accept_children (CodeVisitor visitor) {
		if (type_reference != null) {
			type_reference.accept (visitor);
		}

		if (member_name != null) {
			member_name.accept (visitor);
		}
		
		foreach (Expression arg in argument_list) {
			arg.accept (visitor);
		}

		foreach (MemberInitializer init in object_initializer) {
			init.accept (visitor);
		}
	}

	public override void replace_expression (Expression old_node, Expression new_node) {
		int index = argument_list.index_of (old_node);
		if (index >= 0 && new_node.parent_node == null) {
			argument_list[index] = new_node;
			new_node.parent_node = this;
		}
	}

	public override bool is_pure () {
		return false;
	}

	public override void replace_type (DataType old_type, DataType new_type) {
		if (type_reference == old_type) {
			type_reference = new_type;
		}
	}

	public override bool check (SemanticAnalyzer analyzer) {
		if (checked) {
			return !error;
		}

		checked = true;

		if (member_name != null) {
			member_name.check (analyzer);
		}

		TypeSymbol type = null;

		if (type_reference == null) {
			if (member_name == null) {
				error = true;
				Report.error (source_reference, "Incomplete object creation expression");
				return false;
			}

			if (member_name.symbol_reference == null) {
				error = true;
				return false;
			}

			var constructor_sym = member_name.symbol_reference;
			var type_sym = member_name.symbol_reference;

			var type_args = member_name.get_type_arguments ();

			if (constructor_sym is Method) {
				type_sym = constructor_sym.parent_symbol;

				var constructor = (Method) constructor_sym;
				if (!(constructor_sym is CreationMethod)) {
					error = true;
					Report.error (source_reference, "`%s' is not a creation method".printf (constructor.get_full_name ()));
					return false;
				}

				symbol_reference = constructor;

				// inner expression can also be base access when chaining constructors
				var ma = member_name.inner as MemberAccess;
				if (ma != null) {
					type_args = ma.get_type_arguments ();
				}
			}

			if (type_sym is Class) {
				type = (TypeSymbol) type_sym;
				type_reference = new ObjectType ((Class) type);
			} else if (type_sym is Struct) {
				type = (TypeSymbol) type_sym;
				type_reference = new ValueType (type);
			} else if (type_sym is ErrorCode) {
				type_reference = new ErrorType ((ErrorDomain) type_sym.parent_symbol, (ErrorCode) type_sym, source_reference);
				symbol_reference = type_sym;
			} else {
				error = true;
				Report.error (source_reference, "`%s' is not a class, struct, or error code".printf (type_sym.get_full_name ()));
				return false;
			}

			foreach (DataType type_arg in type_args) {
				type_reference.add_type_argument (type_arg);

				analyzer.current_source_file.add_type_dependency (type_arg, SourceFileDependencyType.SOURCE);
			}
		} else {
			type = type_reference.data_type;
		}

		analyzer.current_source_file.add_symbol_dependency (type, SourceFileDependencyType.SOURCE);

		value_type = type_reference.copy ();
		value_type.value_owned = true;

		int given_num_type_args = type_reference.get_type_arguments ().size;
		int expected_num_type_args = 0;

		if (type is Class) {
			var cl = (Class) type;

			expected_num_type_args = cl.get_type_parameters ().size;

			if (struct_creation) {
				error = true;
				Report.error (source_reference, "syntax error, use `new' to create new objects");
				return false;
			}

			if (cl.is_abstract) {
				value_type = null;
				error = true;
				Report.error (source_reference, "Can't create instance of abstract class `%s'".printf (cl.get_full_name ()));
				return false;
			}

			if (symbol_reference == null) {
				symbol_reference = cl.default_construction_method;
			}

			while (cl != null) {
				if (cl == analyzer.initially_unowned_type) {
					value_type.floating_reference = true;
					break;
				}

				cl = cl.base_class;
			}
		} else if (type is Struct) {
			var st = (Struct) type;

			expected_num_type_args = st.get_type_parameters ().size;

			if (!struct_creation) {
				Report.warning (source_reference, "deprecated syntax, don't use `new' to initialize structs");
			}

			if (symbol_reference == null) {
				symbol_reference = st.default_construction_method;
			}
		}

		if (expected_num_type_args > given_num_type_args) {
			error = true;
			Report.error (source_reference, "too few type arguments");
			return false;
		} else if (expected_num_type_args < given_num_type_args) {
			error = true;
			Report.error (source_reference, "too many type arguments");
			return false;
		}

		if (symbol_reference == null && get_argument_list ().size != 0) {
			value_type = null;
			error = true;
			Report.error (source_reference, "No arguments allowed when constructing type `%s'".printf (type.get_full_name ()));
			return false;
		}

		if (symbol_reference is Method) {
			var m = (Method) symbol_reference;

			var args = get_argument_list ();
			Iterator<Expression> arg_it = args.iterator ();
			foreach (FormalParameter param in m.get_parameters ()) {
				if (param.ellipsis) {
					break;
				}

				if (arg_it.next ()) {
					Expression arg = arg_it.get ();

					/* store expected type for callback parameters */
					arg.target_type = param.parameter_type;
				}
			}

			foreach (Expression arg in args) {
				arg.check (analyzer);
			}

			analyzer.check_arguments (this, new MethodType (m), m.get_parameters (), args);

			foreach (DataType error_type in m.get_error_types ()) {
				// ensure we can trace back which expression may throw errors of this type
				var call_error_type = error_type.copy ();
				call_error_type.source_reference = source_reference;

				add_error_type (call_error_type);
			}
		} else if (type_reference is ErrorType) {
			if (type_reference != null) {
				type_reference.check (analyzer);
			}

			if (member_name != null) {
				member_name.check (analyzer);
			}
		
			foreach (Expression arg in argument_list) {
				arg.check (analyzer);
			}

			foreach (MemberInitializer init in object_initializer) {
				init.check (analyzer);
			}

			if (get_argument_list ().size == 0) {
				error = true;
				Report.error (source_reference, "Too few arguments, errors need at least 1 argument");
			} else {
				Iterator<Expression> arg_it = get_argument_list ().iterator ();
				arg_it.next ();
				var ex = arg_it.get ();
				if (ex.value_type == null || !ex.value_type.compatible (analyzer.string_type)) {
					error = true;
					Report.error (source_reference, "Invalid type for argument 1");
				}
			}
		}

		foreach (MemberInitializer init in get_object_initializer ()) {
			analyzer.visit_member_initializer (init, type_reference);
		}

		return !error;
	}

	public override void get_defined_variables (Collection<LocalVariable> collection) {
		foreach (Expression arg in argument_list) {
			arg.get_defined_variables (collection);
		}
	}

	public override void get_used_variables (Collection<LocalVariable> collection) {
		foreach (Expression arg in argument_list) {
			arg.get_used_variables (collection);
		}
	}

	public override bool in_single_basic_block () {
		foreach (Expression arg in argument_list) {
			if (!arg.in_single_basic_block ()) {
				return false;
			}
		}
		return true;
	}
}
