package nz.co.codec.flexorm
{
    import flash.data.SQLConnection;
    import flash.events.SQLEvent;
    import flash.utils.Dictionary;
    import flash.utils.getDefinitionByName;
    import flash.utils.getQualifiedClassName;

    import mx.collections.ArrayCollection;
    import mx.formatters.DateFormatter;

    import nz.co.codec.flexorm.command.InsertCommand;
    import nz.co.codec.flexorm.command.SQLParameterisedCommand;
    import nz.co.codec.flexorm.command.UpdateCommand;
    import nz.co.codec.flexorm.metamodel.Association;
    import nz.co.codec.flexorm.metamodel.Entity;
    import nz.co.codec.flexorm.metamodel.Field;
    import nz.co.codec.flexorm.metamodel.Identity;
    import nz.co.codec.flexorm.metamodel.ManyToManyAssociation;
    import nz.co.codec.flexorm.metamodel.PersistentEntity;
    import nz.co.codec.flexorm.util.Mixin;
    import nz.co.codec.flexorm.util.StringUtils;

    public class EntityManagerBase
    {
        internal static const OBJECT_TYPE:String = "Object";

        internal static const DEFAULT_SCHEMA:String = "main";

        private var _schema:String;

        private var _sqlConnection:SQLConnection;

        private var _introspector:EntityIntrospector;

        private var _debugLevel:int;

        private var _prefs:Object;

        // A map of Entities using the Entity name as key
        private var _entityMap:Object;

        // Identity Map
        private var cacheMap:Object;

        private var cachedChildrenMap:Object;

        public function EntityManagerBase()
        {
        	init();
        }

		private function init():void {
			_schema = DEFAULT_SCHEMA;
			_prefs = {};
			_prefs.namingStrategy = NamingStrategy.UNDERSCORE_NAMES;
			_prefs.syncSupport = false;
			_prefs.auditable = true;
			_prefs.markForDeletion = true;
			_debugLevel = 0;
			_entityMap = {};
			clearCache();
		}

        public function get schema():String
        {
            return _schema;
        }

        public function set sqlConnection(value:SQLConnection):void
        {
            _sqlConnection = value;

			if(_sqlConnection != null)
				_sqlConnection.addEventListener(SQLEvent.CLOSE, onSqlConnectionClose);

			_introspector = new EntityIntrospector(_schema, value, _entityMap, _debugLevel, _prefs);
        }

        public function get sqlConnection():SQLConnection
        {
            return _sqlConnection;
        }

        public function set introspector(value:EntityIntrospector):void
        {
            _introspector = value;
        }

        public function get introspector():EntityIntrospector
        {
            return _introspector;
        }

        public function set debugLevel(value:int):void
        {
            _debugLevel = value;
            if (_introspector)
                _introspector.debugLevel = value;
        }

        public function get debugLevel():int
        {
            return _debugLevel;
        }

        /**
         * Valid preferences include:
         *
         * - schema:String
         * - namingStrategy:String
         *     Valid values:
         *       NamingStrategy.UNDERSCORE
         *       NamingStrategy.CAMEL_CASE
         *         FlexORM versions prior to 0.8 used camelCase.
         *
         * - syncSupport:Boolean
         * - auditable:Boolean
         * - markForDeletion:Boolean
         *
         */
        public function set prefs(hash:Object):void
        {
            if (hash)
            {
                if (hash.hasOwnProperty("schema"))
                    _schema = hash.schema;
	            for (var key:String in hash)
	            {
	                if (_prefs.hasOwnProperty(key))
	                {
	                    _prefs[key] = hash[key];
	                }
	            }
            }
        }

        public function get prefs():Object
        {
            return _prefs;
        }

        public function get entityMap():Object
        {
            return _entityMap;
        }

        public function makePersistent(cls:Class):void
        {
            Mixin.extendClass(cls, PersistentEntity);

            // A reference to the original class type since a side effect of
            // Mixin is to change cls type to PersistentEntity
            cls.__class = cls;
        }

        protected function getClass(obj:Object):Class
        {
            return (obj is PersistentEntity) ?
                obj.__class :
                Class(getDefinitionByName(getQualifiedClassName(obj)));
        }

        protected function getIdentityMap(key:String, id:*):Object
        {
            var map:Object = {};
            map[key] = id;
            return map;
        }

        protected function getIdentityMapFromInstance(obj:Object, entity:Entity):Object
        {
            var map:Object = {};
            for each(var identity:Identity in entity.identities)
            {
                map[identity.fkProperty] = identity.getValue(obj);
            }
            return map;
        }

        protected function getIdentityMapFromRow(row:Object, entity:Entity):Object
        {
            var map:Object = {};
            for each(var identity:Identity in entity.identities)
            {
                var id:* = getDbColumn(row, identity.column);
/*
				if (!idAssigned(id))
					return null;
*/
                map[identity.fkProperty] = id;
            }
            return map;
        }

        protected function getIdentityMapFromMtmAssociation(row:Object, aMtm:ManyToManyAssociation):Object
        {
            var map:Object = {};
            var entity:Entity = aMtm.associatedEntity;

            for each (var identity:Identity in entity.identities)
            {
                var joinColumnName:String = aMtm.inverseJoinColumns.getColumnNameFromFkProperty(identity.fkProperty);
                var id:* = getDbColumn(row, joinColumnName);
                /*
                   if (!idAssigned(id))
                   return null;
                 */
                map[identity.fkProperty] = id;
            }
            return map;
        }

        protected function getIdentityMapFromAssociation(row:Object, entity:Entity):Object
        {
            var map:Object = {};
            for each(var identity:Identity in entity.identities)
            {
                var id:* = getDbColumn(row, identity.fkColumn);
/*
				if (!idAssigned(id))
					return null;
*/
                map[identity.fkProperty] = id;
            }
            return map;
        }

        protected function combineMaps(maps:Array):Object
        {
            var result:Object = {};
            for each(var map:Object in maps)
            {
                for (var key:String in map)
                {
                    result[key] = map[key];
                }
            }
            return result;
        }

        protected function setIdentMapParams(command:SQLParameterisedCommand, idMap:Object):void
        {
            for (var key:String in idMap)
            {
                command.setParam(key, idMap[key]);
            }
        }

        protected function setIdentityParams(command:SQLParameterisedCommand, obj:Object, entity:Entity):void
        {
            for each(var identity:Identity in entity.identities)
            {
                command.setParam(identity.fkProperty, identity.getValue(obj));
            }
        }

        protected function setFieldParams(command:SQLParameterisedCommand, obj:Object, entity:Entity):void
        {
            for each(var f:Field in entity.fields)
            {
                if (entity.hasCompositeKey() || (f.property != entity.pk.property))
                {
                    command.setParam(f.property, obj[f.property]);
                }
            }
        }

        protected function setOneToOneAssociationParams(command:SQLParameterisedCommand, obj:Object, entity:Entity):void
        {
            for each (var aOto:Association in entity.oneToOneAssociations)
            {
                var associatedEntity:Entity = aOto.associatedEntity;
                var value:Object = obj[aOto.property];

                if (associatedEntity.hasCompositeKey())
                {
                    setIdentityParams(command, value, associatedEntity);
                }
                else
                {
                    if (value == null)
                    {
                        command.setParam(aOto.fkProperty, 0);
                    }
                    else
                    {
                        command.setParam(aOto.fkProperty, value[associatedEntity.pk.property]);
                    }
                }
            }
        }

        protected function setManyToOneAssociationParams(command:SQLParameterisedCommand, obj:Object, entity:Entity):void
        {
            for each(var aMto:Association in entity.manyToOneAssociations)
            {
                var associatedEntity:Entity = aMto.associatedEntity;
                var value:Object = obj[aMto.property];
                if (associatedEntity.hasCompositeKey())
                {
                    setIdentityParams(command, value, associatedEntity);
                }
                else
                {
                    if (value == null)
                    {
                        command.setParam(aMto.fkProperty, 0);
                    }
                    else
                    {
                        command.setParam(aMto.fkProperty, value[associatedEntity.pk.property]);
                    }
                }
            }
        }

        protected function setInsertTimestampParams(insertCommand:InsertCommand, obj:Object):void
        {
        	if (_prefs.syncSupport || _prefs.auditable)
        	{
				var createdAt:Date = new Date();
				var updatedAt:Date = new Date();

				if (obj.hasOwnProperty("createdAt")) obj["createdAt"] = createdAt;
	            insertCommand.setParam("createdAt", createdAt);

				if (obj.hasOwnProperty("updatedAt")) obj["updatedAt"] = updatedAt;
	            insertCommand.setParam("updatedAt", updatedAt);
	        }
        }

        protected function setUpdateTimestampParams(updateCommand:UpdateCommand, obj:Object):void
        {
        	if (_prefs.syncSupport || _prefs.auditable)
        	{
				var updatedAt:Date = new Date();

				if (obj.hasOwnProperty("updatedAt")) obj["updatedAt"] = updatedAt;
	            updateCommand.setParam("updatedAt", updatedAt);
	        }
        }

        protected function isCascadeSave(a:Association):Boolean
        {
            return (a.cascadeType == CascadeType.SAVE_UPDATE || a.cascadeType == CascadeType.ALL);
        }

        protected function isCascadeDelete(a:Association):Boolean
        {
            return (a.cascadeType == CascadeType.DELETE || a.cascadeType == CascadeType.ALL);
        }

        protected function getClassName(c:Class):String
        {
            var qname:String = getQualifiedClassName(c);
            return qname.substring(qname.lastIndexOf(":") + 1);
        }

        protected function setCachedValue(obj:Object, entity:Entity):void
        {
            getCache(entity.name)[getIdentityMapFromInstance(obj, entity)] = obj;
        }

        protected function getCachedAssociationValue(a:Association, row:Object):Object
        {
            var associatedEntity:Entity = a.associatedEntity;
            if (associatedEntity.hasCompositeKey())
            {
                return getCachedValue(associatedEntity, getIdentityMapFromAssociation(row, associatedEntity));
            }
            else
            {
                return getCachedValue(associatedEntity, getIdentityMap(associatedEntity.fkProperty, getDbColumn(row, a.fkColumn)));
            }
        }

        protected function getCachedValue(entity:Entity, cacheKey:Object):Object
        {
            if (cacheKey == null)
                return null;

            var cache:Dictionary = getCache(entity.name);
            for (var ck:Object in cache)
            {
                var match:Boolean = true;
                for (var k:String in cacheKey)
                {
                    if (cacheKey[k] != ck[k])
                    {
                        match = false;
                        break;
                    }
                }
                if (match)
                    return cache[ck];
            }
            return null;
        }

        private function getCache(name:String):Dictionary
        {
            var cache:Dictionary = cacheMap[name];
            if (cache == null)
            {
                cache = new Dictionary();
                cacheMap[name] = cache;
            }
            return cache;
        }

        protected function clearCache():void
        {
            cacheMap = {};
            cachedChildrenMap = {};
        }

        protected function getCachedChildren(parentId:int):ArrayCollection
        {
            var coll:ArrayCollection = cachedChildrenMap[parentId];
            if (coll == null)
            {
                coll = new ArrayCollection();
                cachedChildrenMap[parentId] = coll;
            }
            return coll;
        }

        protected function isDynamicObject(obj:Object):Boolean
        {
            return (OBJECT_TYPE == getClassName(getClass(obj)));
        }

        protected function idAssigned(id:*):Boolean
        {
            return ((id is int && id > 0) || (id is String && id != null));
        }

		protected function onSqlConnectionClose( e : SQLEvent ) :void
		{
			this.init();
		}

        protected function getDbColumn(row:Object, columnName:String):*
        {
            var res:* = null;

            if (columnName != null) // shortcut (no need to search through)
            {
				for (var attr:String in row)
				{
					if (StringUtils.stringsEqualCaseIgnored(attr, columnName))
					{
						res = row[attr];
						break;
					}
				}
			}
			return res;
        }

        protected function ConvertToDate(entry:*):Date
        {
            if (entry == null)
            {
                return null;
            }

            // Views return a Number or String instead of a Date (which cannot be cast to Date type)
            if (entry is Date)
            {
                return entry;
            }

            if (entry is Number)
            {
                // JD 2440587.500000 is CE 1970 January 01 00:00:00.0 UT  Thursday
                const julianOffset:Number = 2440587.5;
                return new Date((entry - julianOffset) * 24 * 60 * 60 * 1000);
            }

            if (entry is String)
            {
                // format is probably "YYYY-MM-DD HH:MM:SS"
                return DateFormatter.parseDateString(entry);
            }

            return null; // unknown type
        }

	}
}