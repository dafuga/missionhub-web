(function () {
    'use strict';

    angular
        .module('missionhubApp')
        .component('organizationOverview', {
            controller: organizationOverviewController,
            bindings: {
                org: '<',
                loadDetails: '<?'
            },
            templateUrl: /* @ngInject */ function (templateUrl) {
                return templateUrl('organizationOverview');
            }
        });

    function organizationOverviewController ($scope, JsonApiDataStore, asyncBindingsService, ministryViewTabs,
                                             organizationOverviewService, organizationService, loggedInPerson, _) {
        var vm = this;
        vm.tabNames = ministryViewTabs;
        vm.adminPrivileges = true;
        vm.cruOrg = false;
        vm.$onInit = asyncBindingsService.lazyLoadedActivate(activate, ['org']);

        function activate () {
            _.defaults(vm, {
                loadDetails: true
            });

            vm.adminPrivileges = loggedInPerson.isAdminAt(vm.org);
            var cruOrgId = '1';
            vm.cruOrg = organizationService.getOrgHierarchyIds(vm.org)[0] === cruOrgId;

            if (!vm.loadDetails) {
                // Abort before loading org details
                return;
            }

            // Make groups and surveys mirror that property on the organization
            $scope.$watch('$ctrl.org.groups', function () {
                vm.groups = vm.org.groups;
            });
            $scope.$watch('$ctrl.org.surveys', function () {
                vm.surveys = vm.org.surveys;
            });

            // Find all of the groups and surveys related to the org
            organizationOverviewService.loadOrgRelations(vm.org);

            // The suborgs, people, and team are loaded by their respective tab components, not this component.
            // However, this component does need to know how many people and team members there are, so set the
            // people and team to a sparse array of the appropriate length.
            organizationOverviewService.getSubOrgCount(vm.org).then(function (subOrgCount) {
                vm.suborgs = new Array(subOrgCount);
            });
            organizationOverviewService.getPersonCount(vm.org).then(function (personCount) {
                vm.people = new Array(personCount);
            });
            organizationOverviewService.getTeamCount(vm.org).then(function (teamMemberCount) {
                vm.team = new Array(teamMemberCount);
            });
        }
    }
})();
