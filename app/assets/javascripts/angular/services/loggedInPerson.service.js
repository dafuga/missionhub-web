(function () {
    angular
        .module('missionhubApp')
        .factory('loggedInPerson', loggedInPerson);

    function loggedInPerson (httpProxy, apiEndPoint, JsonApiDataStore) {
        var person = null;

        // Load the logged-in user's profile
        function loadMe () {
            return httpProxy.get(apiEndPoint.people.me, {
                include: 'user,organizational_permissions.organization'
            })
            .then(function (response) {
                JsonApiDataStore.store.sync(response);

                // Lookup the user associated with the returned person
                var personId = response.data.id;
                return JsonApiDataStore.store.find('person', personId);
            });
        }

        loadMe().then(function (me) {
            person = me;
        });

        // This service exposes an object with a person property that will be set to person model, or null if it has
        // not yet been loaded.
        return {
            get person () {
                return person;
            }
        };
    }
})();
