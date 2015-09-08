/**
 * Created by christoferdutz on 31.08.15.
 */
package org.dukecon.controller {
import flash.data.SQLConnection;
import flash.data.SQLResult;
import flash.data.SQLStatement;
import flash.errors.SQLError;
import flash.events.EventDispatcher;
import flash.filesystem.File;

import mx.collections.ArrayCollection;
import mx.messaging.messages.HTTPRequestMessage;
import mx.rpc.AsyncToken;
import mx.rpc.Responder;
import mx.rpc.events.FaultEvent;
import mx.rpc.events.ResultEvent;
import mx.rpc.http.HTTPService;

import org.dukecon.events.ConferenceDataChangedEvent;
import org.dukecon.events.UserPreferenceDataChangedEvent;
import org.dukecon.model.Talk;
import org.dukecon.model.UserPreference;
import org.dukecon.model.UserPreferenceBase;

[Event(type="org.dukecon.events.UserPreferenceDataChangedEvent", name="userPreferenceDataChanged")]
public class UserPreferenceController extends EventDispatcher {

    private var getService:HTTPService;
    private var addService:HTTPService;
    private var removeService:HTTPService;

    private var conn:SQLConnection;
    private var db:File;

    private var uncommittedAdditions:ArrayCollection = new ArrayCollection();
    private var uncommittedDeletes:ArrayCollection = new ArrayCollection();

    [Inject]
    public var oauthController:OAuthControllerSimple;

    public var baseUrl:String;

    public function UserPreferenceController() {
    }

    [Init]
    public function init():void {
        getService = new HTTPService();
        getService.contentType = "application/json";
        getService.method = HTTPRequestMessage.GET_METHOD;
        getService.url = baseUrl + "/rest/noauthpreferences";

        addService = new HTTPService();
        addService.contentType = "application/json";
        addService.method = HTTPRequestMessage.POST_METHOD;
        addService.url = baseUrl + "/rest/noauthpreferences?_method=PUT";

        removeService = new HTTPService();
        removeService.contentType = "application/json";
        removeService.method = HTTPRequestMessage.POST_METHOD;
        removeService.url = baseUrl + "/rest/noauthpreferences?_method=DELETE";

        // This file will be used for storing the data on the device.
        var db:File = File.applicationStorageDirectory.resolvePath("dukecon-user-preferences.db");
        // This file will be located in
        var initDb:Boolean = !db.exists;

        // Initialize the database.
        conn = new SQLConnection();
        try {
            conn.open(db);
            if (initDb) {
                UserPreferenceBase.createTable(conn);
            }
        } catch (error:SQLError) {
            trace("Error message:", error.message);
        }
    }

    public function readUserPreferences():void {
        if (oauthController.oauthData) {
            trace("Get");
            getService.headers = {
                Accept: "application/json",
                Authorization: "Bearer " + oauthController.oauthData.access_token
            };
            var token:AsyncToken = getService.send();
            token.addResponder(new Responder(function (event:ResultEvent):void {
                var result:Object = JSON.parse(String(event.result));

                // Flush the table and add each user preference returned by the server.
                UserPreferenceBase.clearTable(conn);
                var selectedTalkIds:ArrayCollection = new ArrayCollection();
                for each(var obj:Object in result as Array) {
                    var userPreference:UserPreference = new UserPreference(obj);
                    userPreference.persist(conn);
                    selectedTalkIds.addItem(userPreference.talkId);
                }
                trace("Got: " + result.length + " preferences.");

                // If there are outstanding creations or deletions, replay them now.
                if (uncommittedAdditions.length > 0) {
                    trace("Replaying uncommitted additions:");
                    for each(var addition:UserPreference in uncommittedAdditions) {
                        // Only re-send the addition if the talk was not
                        // selected, as it could have been added by another
                        // client.
                        if (!selectedTalkIds.contains(addition.talkId)) {
                            addUserPreference(addition);
                        }
                    }
                    trace("Done replaying uncommitted additions.");
                }
                if (uncommittedDeletes.length > 0) {
                    trace("Replaying uncommitted deletions:");
                    for each(var deletion:UserPreference in uncommittedDeletes) {
                        // Only re-send the deletion if the talk was still
                        // selected, as it could have been removed by another
                        // client.
                        if (selectedTalkIds.contains(addition.talkId)) {
                            deleteUserPreference(deletion);
                        }
                    }
                    trace("Done replaying uncommitted deletions.");
                }

                dispatchEvent(new ConferenceDataChangedEvent(UserPreferenceDataChangedEvent.USER_PREFERENCE_DATA_CHANGED));
            }, onFault));
        }
    }

    public function addUserPreference(userPreference:UserPreference):void {
        // Add the user preference to a uncommitted changes list from
        // which it is removed as soon as the write method was successful.
        if (!uncommittedAdditions.contains(userPreference)) {
            uncommittedAdditions.addItem(userPreference);
        }

        if (oauthController.oauthData) {
            trace("Add: " + userPreference.talkId);
            addService.headers = {
                Accept: "application/json",
                Authorization: "Bearer " + oauthController.oauthData.access_token
            };
            var jsonString:String = JSON.stringify(userPreference);
            var token:AsyncToken = addService.send(jsonString);
            token.userPreference = userPreference;
            token.addResponder(new Responder(function (event:ResultEvent):void {
                var userPreference:UserPreference = UserPreference(event.token.userPreference);
                uncommittedAdditions.removeItem(userPreference);
                trace("Added: " + userPreference.talkId);
            }, onFault));
        } else {
            trace("Added locally: " + userPreference.talkId);
        }
    }

    public function deleteUserPreference(userPreference:UserPreference):void {
        // If the user preference was located in the list of uncommitted
        // additions, it's safe to remove it from that list.
        if (uncommittedAdditions.contains(userPreference)) {
            uncommittedAdditions.removeItem(userPreference);
        }
        // Add the user preference to a uncommitted changes list from
        // which it is removed as soon as the write method was successful.
        if (!uncommittedDeletes.contains(userPreference)) {
            uncommittedDeletes.addItem(userPreference);
        }

        if (oauthController.oauthData) {
            trace("Remove: " + userPreference.talkId);
            removeService.headers = {
                Accept: "application/json",
                Authorization: "Bearer " + oauthController.oauthData.access_token
            };
            var jsonString:String = JSON.stringify(userPreference);
            var token:AsyncToken = removeService.send(jsonString);
            token.userPreference = userPreference;
            token.addResponder(new Responder(function (event:ResultEvent):void {
                var userPreference:UserPreference = UserPreference(event.token.userPreference);
                uncommittedDeletes.removeItem(userPreference);
                trace("Removed: " + userPreference.talkId);
            }, onFault));
        } else {
            trace("Removed locally: " + userPreference.talkId);
        }
    }

    protected function onFault(fault:FaultEvent):void {
        var userPreference:UserPreference = UserPreference(fault.token.userPreference);

        // This is usually returned if we try to add something, that already there.
        // The only time this should happen, is if the same item had been added
        // by a different client. So it's safe to ignore the error response.
        if (fault.statusCode == 409) {
            uncommittedAdditions.removeItem(userPreference);
            trace("Added (duplicate): " + userPreference.talkId);
        }
        // This is usually returned if we try to remove something, that's not there.
        // The only time this should happen, is if the same item had been removed
        // by a different client. So it's safe to ignore the error response.
        else if (fault.statusCode == 404) {
            uncommittedDeletes.removeItem(userPreference);
            trace("Removed (non-existent): " + userPreference.talkId);
        }
        // In all other cases something went wrong, so let's at least log it.
        else {
            trace("Something went wrong:" + fault.message);
        }
    }

    public function get userPreferences():ArrayCollection {
        var talks:ArrayCollection = UserPreferenceBase.select(conn);
        return talks;
    }

    public function isTalkSelected(talk:Talk):Boolean {
        if (!talk) return false;
        var userPreferences:ArrayCollection = executeQuery("SELECT DISTINCT talkId FROM UserPreference WHERE talkId = '" + talk.id + "'");
        return userPreferences && (userPreferences.length > 0);
    }

    public function selectTalk(talk:Talk):void {
        if (!talk) return;
        var userPreference:UserPreference = new UserPreference();
        userPreference.talkId = talk.id;
        userPreference.version = 0;
        userPreference.persist(conn);

        // Write the preferences back to the server.
        addUserPreference(userPreference);
    }

    public function unselectTalk(talk:Talk):void {
        if (!talk) return;
        var userPreferences:ArrayCollection = UserPreferenceBase.select(conn, "talkId = " + talk.id);
        if (userPreferences != null) {
            executeQuery("DELETE FROM UserPreference WHERE talkId = '" + talk.id + "'");

            // Write the preferences back to the server.
            deleteUserPreference(userPreferences[0]);
        }
    }

    protected function executeQuery(query:String):ArrayCollection {
        var result:ArrayCollection = new ArrayCollection();
        var selectStatement:SQLStatement = new SQLStatement();
        selectStatement.sqlConnection = conn;
        selectStatement.text = query;
        try {
            selectStatement.execute();
            var sqlResult:SQLResult = selectStatement.getResult();
            for each(var obj:Object in sqlResult.data) {
                result.addItem(obj);
            }
        } catch (initError:SQLError) {
            throw new Error("Error selecting records from table '${jClass.as3Type.name}': " + initError.message);
        }
        return result;
    }

}
}