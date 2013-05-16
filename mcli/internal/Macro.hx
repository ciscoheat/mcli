package mcli.internal;
import haxe.macro.*;
import haxe.macro.Type;
import haxe.macro.Expr;
import mcli.internal.Data;
using haxe.macro.TypeTools;
using haxe.macro.ComplexTypeTools;
using Lambda;

class Macro
{
	private static var types:Map<String,{ found:Bool, declaredPos:Null<Position>, parentType:String }> = new Map();
	private static var usedTypes:Map<String,Array<Position>> = new Map();
	private static var once = false;

	private static function ensureArgs(name, args, nargs, p)
	{
		if (args.length != nargs)
			throw new Error("Invalid number of type parameters for $name. Expected $nargs", p);
	}

	public static function convertType(t:haxe.macro.Type, pos:Position):mcli.internal.Type
	{
		return switch(Context.follow(t))
		{
			case TInst(c,_): c.toString();
			case TEnum(e,_): e.toString();
			case TAbstract(a,_): a.toString();
			default:
				throw new Error("The type " + t.toString() + " is not supported by the CLI dispatcher", pos);
		}
	}

	public static function build()
	{
		//reset statics for each reused context
		if (!once)
		{
			Context.onMacroContextReused(function()
			{
				resetContext();
				return true;
			});
			resetContext();
			once = true;
		}

		//collect all @:arg members, and add a static
		var fields = Context.getBuildFields();
		var ctor = null, setters = [];
		var arguments = [];
		for (f in fields)
		{
			//no statics allowed
			if (f.access.has(AStatic)) continue;
			if (f.name == "new")
			{
				ctor = f;
				continue;
			}

			var meta = null;
			for(m in f.meta) if (m.name == ":arg") meta = m;
			if (meta != null)
			{
				var type = switch(f.kind)
				{
					case FVar(t, e), FProp(_, _, t, e):
						if (e != null)
						{
							f.kind = switch f.kind
							{
								case FVar(t,e):
									setters.push(macro this.$(f.name) = $e);
									FVar(t,null);
								case FProp(get,set,t,e):
									setters.push(macro this.$(f.name) = $e);
									FProp(get,set,t,null);
							};
						}

						if (t == null)
						{
							if (e == null) throw new Error("A field must either be fully typed, or be initialized with a typed expression", f.pos);
							try
							{
								Context.typeof(e, f.pos);
							}
							catch(d:Dynamic)
							{
								throw new Error("Dispatch field cannot build with error: $d . Consider using a constant, or a simple expression", f.pos);
							}
						} else {
							t.toType();
						}
					case FFun(f):
						var f = { ret : null, params: [], expr: macro {}, args: f.args };
						Context.typeof({ expr: EFunction(null,f), pos: f.pos });
				};
				var command = macro ${f.name};
				var description = meta.params[0];
				if (meta.params.length > 2)
					command = meta.params[2];
				aliases = meta.params[1];

				if (aliases == null) aliases = macro null;
				if (description == null) description = macro null;

				var kind = switch(Context.follow(type))
				{
					case TAbstract(a,[p1,p2]) if (a.toString() == "Map"):
						var arr = arrayType(p2);
						if (arr != null) p2 = arr;
						VarHash(convertType(p1, f.pos), convertType(p2, f.pos), arr != null);
					case TInst(c,[p1]) if (c.toString() == "haxe.ds.StringMap" || c.toString() == "haxe.ds.IntMap"):
						var arr = arrayType(p1);
						if (arr != null) p1 = arr;
						VarHash( c.toString() == "haxe.ds.StringMap" ? "String":"Int", convertType(p1, f.pos), arr != null );
					case TAbstract(a,[]) if (a.toString() == "Bool"):
						Flag;
					case TFun([arg],ret) if (isDispatch(arg.t)):
						SubDispatch;
					case TFun(args,ret):
						var args = args.copy();
						var last = args.pop();
						var varArg = null;
						if (last != null && last.name == "varArgs")
						{
							switch(Context.follow(last.t))
							{
								case TInst(a,[t]) if (a.toString() == "Array"):
									varArg = convertType(t, f.pos);
								default:
									args.push(last);
							}
						}
						Function(args.map(function(a) return convertType(a.t, f.pos)), varArg);
					default:
						Var( convertType(type, f.pos) );
				};
				var kind = Context.makeExpr(kind, f.pos);
				arguments.push(macro { command:$command, aliases:$aliases, description:$description, kind:$kind });
			}
		}

		if (setters.length != 0)
		{
			if (ctor != null)
			{
				switch(ctor.kind)
				{
					case FFun(f):
						if (f.expr != null)
						{
							setters.push(f.expr);
						}
						f.expr = { expr: EBlock(setters), pos: ctor.pos };
					default: throw "assert";
				}
			} else {
				ctor = { pos: Context.currentPos(), name:"new", meta: [], doc:null, access:[], kind:FFun({
					ret: null,
					params: [],
					expr: { expr : EBlock(setters), pos: Context.currentPos() },
					args: []
				}) };
				fields.push(ctor);
			}
		}

		if (arguments.length == 0)
		{
			Context.warning("This class has no @:arg macros", Context.currentPos());
		} else {
			fields.push({
				pos: Context.currentPos(),
				name:"ARGUMENTS",
				meta: [],
				doc:null,
				access: [AStatic],
				kind:FVar(null, { expr: EArrayDecl(arguments), pos: Context.currentPos() })
			});
		}
		return fields;
	}

	private static function isDispatch(t:Type)
	{
		return switch(Context.follow(t))
		{
			case TInst(c,_):
				if (c.toString() == "mcli.Dispatch")
					true;
				else if (c.get().superClass == null)
					false;
				else
					isDispatch(TInst(c.get.superClass.t,null));
			default: false;
		}
	}

	private static function arrayType(t:Type)
	{
		return switch(Context.follow(t))
		{
			case TInst(c,[p]) if (c.toString() == "Array"): p;
			default: null;
		}
	}

	public static function registerUse(t:String, declaredPos:Position, parentType:String)
	{
		var g = types.get(t);
	}

	public static function registerDecoder(t:String)
	{
		var g = types.get(t);
		if (g == null)
		{
			types.set(t, { found:true, declaredPos:null, parentType:null });
		} else {
			g.found = true;
		}
	}

	private static function getName(t:haxe.macro.Type)
	{
		return switch(Context.follow(t))
		{
		case TInst(c,_): c.toString();
		case TEnum(e,_): e.toString();
		case TAbstract(a,_): a.toString();
		default: null;
		}
	}

	private static function conformsToDecoder(t:haxe.macro.Type):Bool
	{
		switch(t)
		{
		case TInst(c,_):
			var c = c.get();
			//TODO: test actual type
			return c.statics.get().exists(function(cf) return cf.name == "ofString");
		default: return false;
		}
	}

	private static function resetContext()
	{
		usedTypes = new Map();
		Context.onGenerate(function(btypes)
		{
			//see if all types dependencies are met
			for (k in types.keys())
			{
				var t = types.get(k);
				if (t != null && !t.found)
				{
					//check if the declared type is declared and conforms to the Decoder typedef
					for (bt in btypes)
					{
						if ( (getName(bt) == k || getName(bt) == k + "Decoder") && conformsToDecoder(bt))
						{
							t.found = true;
						}
					}

					if (!t.found)
					{
						if (t.declaredPos == null) throw "assert"; //should never happen; declaredPos is null only for found=true
						Context.warning("The type $k is used by a nano cli Dispatcher but no Decoder was declared", t.declaredPos);
						//FIXME: for subsequent compiles using the compile server, this information will not show up
						var usedAt = usedTypes.get(t.parentType);
						if (usedAt != null)
						{
							for (p in usedAt)
								Context.warning("Last warning's type used here", p);
						}
					}
				}
			}
		});
	}
				//registerModuleReuseCall
				// case "haxe.ds.StringMap", "haxe.ds.IntMap":
				// 	if (insideFunction)
				// 		throw new Error("This type is not allowed inside a function", pos);
				// 	ensureArgs(c.toString(), p, 1, pos);
				// 	VarHash(c.toString() == "haxe.ds.StringMap" ? TString : TInt, convertType(p[0], insideFunction, pos));
}
