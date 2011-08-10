// Jonathan Hersh - jhersh@salesforce.com - Feb '11
//

public with sharing class groupMaster {
    // operation types
    public string operation             { get; set; }
    public static string MERGE_OP       { get { return 'merge'; } }
    public static string COPY_OP        { get { return 'copy'; } }
    public static string MEMBER_OP      { get { return 'members'; } }
    
    // Defines to govern our batch processes
    public static integer MAX_BATCH_JOBS = 5;
    public static integer MAX_GROUP_JOBS = 1;
    
    public boolean isTest               { get; set; }
    
    // Editing tables
    public string IDToRemove            { get; set; }
    
    // Status display
    public integer jobsExecuted         { get; set; }
    public string statusMsg             { get; set; }
    public string targetURL             { get; set; }
    
    // Merging
    public string destGroup             { get; set; }
    public string sourceGroup           { get; set; }
    public string sourceGroupName       { get; set; }
    public groupWrapper[] sourceGroups  { get; set; }
    public boolean deleteSources        { get; set; }
    
    // Copying
    public string copySource            { get; set; }
    public string newName               { get; set; }
    public boolean doNotCopyPosts       { get; set; }
    
    // Adding members
    public rpWrapper[] memberSources    { get; set; }
    public integer whichSelect          { get; set; }
    public string sourceGroupID         { get; set; }
    public string sourceRoleID          { get; set; }
    public string sourceProfileID       { get; set; }
    public string destGroupID           { get; set; }
    
    public groupMaster() {
        isTest = false;     
        
        reset();
    }
    
    public void reset() {
        jobsExecuted = 0;
        whichSelect = 0;
        sourceGroups = new groupWrapper[] {};
        memberSources = new rpWrapper[] {};
        statusMsg = '';
        operation = 'merge';
        targetURL = '';
        destGroup = '';
        sourceGroup = null;
        deleteSources = false;
        copySource = '';
        newName = '';
        doNotCopyPosts = false;
        sourceGroupID = '';
        sourceRoleID = '';
        sourceProfileID = '';
        destGroupID = '';
        
        getGroupList();
    }
    
    // Returns true if we are currently doing a groupmaster calculation or if
    // we are unable to start one because of the number of batch jobs already underway.
    // Returns false if we are eligible to start a calculation
    public boolean getGroupMasterIsCalculating() {
        // How many other jobs are in progress?
        integer currentJobs = integer.valueof( [Select count(id) jobs from AsyncApexJob 
            where jobtype = 'BatchApex' 
            and ( status = 'Queued' or status = 'Processing' or status = 'Preparing' ) ].get(0).get('jobs') );
            
        if( currentJobs >= MAX_BATCH_JOBS )
            return true;
            
        // We only start another data load if there is not currently one executing
        ApexClass[] myClasses = [select id from ApexClass where name = 'groupMasterBatch'];
        AsyncApexJob[] myJobs = [Select id, jobitemsprocessed, totaljobitems, status from AsyncApexJob 
                    where jobtype = 'BatchApex' 
                    and ( status = 'Queued' or status = 'Processing' or status = 'Preparing' )
                    and apexclassid IN :myClasses
                    order by createddate asc];  
                    
        if( myJobs.isEmpty() ) 
            return false;
                    
        if( myJobs[0].status == 'Queued' )
            statusMsg = 'Waiting for queued data load to begin.';
        else if( myJobs[0].status == 'Preparing' )
            statusMsg = 'Preparing data load.';
        else if( myJobs[0].status == 'Processing' )
            statusMsg = 'Processed '+ myJobs[0].JobItemsProcessed +' of '+ myJobs[0].TotalJobItems +' total batches.';
            
        return myJobs.size() >= MAX_GROUP_JOBS;
    }
    
    // Returns the total number of batch jobs that need to be run for a given operation
    public integer getBatchCount() {
        if( operation == MERGE_OP ) {
            return 2;
        } else if( operation == COPY_OP ) {
            return 1 + ( !doNotCopyPosts ? 1 : 0 );
        } else if( operation == MEMBER_OP ) {
            return 2;
        }
        
        return 1;
    }
    
    public void launchBatch() {
        statusMsg = '';
                
        // Are we eligible to start a batch process?
        if( getGroupMasterIsCalculating() ) 
            return;
        
        jobsExecuted++;     
        
        if( jobsExecuted > getBatchCount() )
            return;
        
        groupMasterBatch gm = new groupMasterBatch();
        Set<ID> sources = new Set<ID> ();
                
        // Validate we have all our required inputs
        if( operation == MERGE_OP ) {           
            for( groupWrapper g : sourceGroups )
                if( !sources.contains( g.groupID ) )
                    sources.add( g.groupID );
                    
            sources.remove( destGroup );
            
            if( sources.isEmpty() || destGroup == null || destGroup == '' )
                return;
                
            // If this is the first load, do members. otherwise, do posts
            if( jobsExecuted == 1 && !isTest )
                gm.opType = MEMBER_OP;
            else
                gm.opType = MERGE_OP;
            
            gm.destID = destGroup;
            targetURL = destGroup;
            
            gm.deleteSources = deleteSources;
        } else if( operation == COPY_OP ) {
            // Make sure a source group is selected, and the dest group has a name
            if( copySource == null || copySource == '' || newName == null || newName == '' )
                return;
                    
            sources.add( copySource );
            
            // Does this group exist? If not, create it
            CollaborationGroup[] cgs = [select id, name from CollaborationGroup
                    where name = :newName];
                    
            if( cgs.isEmpty() ) {
                CollaborationGroup[] source = [select id, name, collaborationtype, description, ownerid, informationbody, informationtitle from CollaborationGroup where id = :copySource];
                    
                CollaborationGroup cg = source.deepClone( false ).get(0);
                cg.name = newName;
                    
                try {
                    insert cg;
                } catch( Exception e ) {
                    ApexPages.addMessages( e );
                    return;
                }
                    
                gm.destID = cg.id;
            } else
                gm.destID = cgs[0].id;
                
            targetURL = gm.destID;  
                
            // If this is the first load, do members. otherwise, do posts
            if( jobsExecuted == 1 && !isTest ) {
                gm.opType = MEMBER_OP;
            } else
                gm.opType = COPY_OP;
        } else if( operation == MEMBER_OP ) {
            if( memberSources.isEmpty() || destGroupID == null ) 
                return;
                
            // Split these IDs into group and non-group (role/profile) buckets
            String gPrefix = Schema.Sobjecttype.CollaborationGroup.getKeyPrefix();
            ID[] groupIDs = new ID[] {};
            ID[] rpIDs = new ID[] {};
            
            targetURL = destGroupID;
            
            for( rpWrapper rp : memberSources )
                if( (''+ rp.rpID).substring( 0, 3 ) == gPrefix )
                    groupIDs.add( rp.rpID );
                else
                    rpIDs.add( rp.rpID );
                                
            if( jobsExecuted == 1 )
                sources.addAll( groupIDs );
            else
                sources.addAll( rpIDs );
                    
            sources.remove( destGroupID );
                        
            if( sources.isEmpty() )
                return;
            
            gm.destID = destGroupID;
            gm.opType = MEMBER_OP;
        }
    
        gm.sourceIDs = sources;
                
        // Engage
        Database.executeBatch(gm);
    }
    
    // Adds a group, role, or profile to the list of groups/roles/profiles to add
    public void addGRP() {
        Set<ID> existingIDs = new Set<ID> ();
        
        for( rpWrapper rp : memberSources )
            existingIDs.add( rp.rpID );
            
        if( whichSelect == 1 && sourceGroupID != null && !existingIDs.contains( sourceGroupID ) )
            memberSources.add( new rpWrapper( sourceGroupID, 
            [select name from CollaborationGroup where id = :sourceGroupID].name,
            'Group' ) );
        
        if( whichSelect == 2 && sourceRoleID != null && !existingIDs.contains( sourceRoleID ) )
            memberSources.add( new rpWrapper( sourceRoleID, 
            [select name from UserRole where id = :sourceRoleID].name,
            'Role' ) );
        
        if( whichSelect == 3 && sourceProfileID != null && !existingIDs.contains( sourceProfileID ) )
            memberSources.add( new rpWrapper( sourceProfileID, 
            [select name from Profile where id = :sourceProfileID].name,
            'Profile' ) );
    }
    
    // Removes a group, role, or profile from the list
    public void removeGRP() {
        if( IDToRemove == null || IDToRemove == '' )
            return;
            
        rpWrapper[] tmp = new rpWrapper[] {};
        
        for( rpWrapper rp : memberSources )
            if( rp.rpID != IDToRemove )
                tmp.add( rp );
                
        memberSources = tmp;
    }
    
    // Adds a group to the list of groups to merge
    public void addGroup() {
        if( sourceGroup == null || sourceGroup == '' )
            return;
        
        for( groupWrapper g : sourceGroups )    
            if( g.groupID == sourceGroup )
                return;
                
        CollaborationGroup cg;
        
        try {
            cg = [select id, name, membercount, smallphotourl from CollaborationGroup where id = :sourceGroup];
        } catch( Exception e ) {
            ApexPages.addMessages( e );
            return;
        }
            
        sourceGroups.add( new groupWrapper( cg.id, cg.name, cg.membercount, cg.smallphotourl ) );
    }
    
    // Removes a group from the list of groups to merge
    public void removeGroup() {
        if( IDToRemove == null || IDToRemove == '' )
            return;
            
        groupWrapper[] tmp = new groupWrapper[] {};
        
        for( groupWrapper gw : sourceGroups )
            if( gw.groupID != IDToRemove )
                tmp.add( gw );
                
        sourceGroups = tmp;
    }
    
    public void clearGroups() {
        sourceGroup = '';
        sourceGroups.clear();
    }
    
    public void selectedSource() {
        if( copySource == null || copySource == '' ) {
            newName = '';
            return;
        }
        
        CollaborationGroup cg;
        
        try {
            cg = [select id, name from CollaborationGroup where id = :copySource];
        } catch( Exception e ) {
            ApexPages.addMessages( e );
            return;
        }
        
        newName = cg.name +' copy';
    }
    
    public SelectOption[] getOperations() {
        SelectOption[] so = new SelectOption[] {};
        
        so.add( new SelectOption( MERGE_OP, 'Group Merge') );
        so.add( new SelectOption( COPY_OP, 'Group Copy') );
        so.add( new SelectOption( MEMBER_OP, 'Mass Add Group Members') );
        
        return so;
    }
    
    public SelectOption[] getGroupList() {
        SelectOption[] so = new SelectOption[] {};
        
        so.add( new SelectOption('','-- Select a Group --'));
        
        for( CollaborationGroup cg : [select id, name, membercount from CollaborationGroup order by name asc, membercount desc limit :( isTest ? 5 : 1000 )] )
            so.add( new SelectOption( cg.id, cg.name +' ('+ cg.membercount + ( cg.membercount > 1 ? ' members' : ' member' ) + ')' ) );
            
        return so;
    }
    
    // List of profiles to invite
  public SelectOption[] getProfiles() {
    SelectOption[] so = new SelectOption[] {};
    
    so.add( new SelectOption('','-- Select a Profile --'));
    
    Profile[] ps = [select id, name
        from Profile
        where usertype = 'Standard'
        order by name asc limit :( isTest ? 5 : 1000 )];
    
    for( Profile p : ps )
        so.add( new SelectOption( p.id, p.name ) );
    
    return so;      
  }
  
  // List of roles to invite
  public SelectOption[] getRoles() {
    SelectOption[] so = new SelectOption[] {};
    
    so.add( new SelectOption('','-- Select a Role --'));
    
    UserRole[] rs = [select id, name
        from UserRole
        where portaltype = 'None'
        order by name asc limit :( isTest ? 5 : 1000)];
    
    for( UserRole r : rs )
        so.add( new SelectOption( r.id, r.name ) );
    
    return so;      
  }
    
    public class groupWrapper {
        public ID groupID       { get; set; }
        public string groupName { get; set; }   
        public integer members  { get; set; }
        public string photoURL  { get; set; }
        
        public groupWrapper( ID gID, string gName, integer m, string p ) {
            groupID = gID;
            groupName = gName;
            members = m;
            photoURL = p;
        }   
    }
    
    public class rpWrapper {
        public ID rpID          { get; set; }
        public string rpName    { get; set; }   
        public string rpType    { get; set; }
        
        public rpWrapper( ID rp, string name, string t ) {
            rpID = rp;
            rpName = name;
            rpType = t;
        }
    }
    
    public static testmethod void runTest() {
        groupMaster gm = new groupMaster();
        gm.isTest = true;
        
        gm.getRoles();
        gm.getProfiles();
        gm.getGroupList();
        gm.clearGroups();
        gm.getOperations();
        gm.getGroupMasterIsCalculating();
        gm.reset();
        
        // Create some new groups
        CollaborationGroup cg = new CollaborationGroup( name = 'groupMaster Test Group', collaborationtype = 'Public' );
        CollaborationGroup cg2 = new CollaborationGroup( name = 'groupMaster Test Group 2', collaborationtype = 'Public' );
        
        insert new CollaborationGroup[] { cg, cg2 };
        
        FeedItem fp = new FeedItem( body = 'test post', parentid = cg.id, createdbyid = userinfo.getuserid() );
        insert fp;
        
        //CollaborationGroupFeed cgf = [select id from CollaborationGroupFeed
        //    where feeditemid = :fp.id];
            
        FeedComment fc = new FeedComment( commentbody = 'test comment', feeditemid = fp.id );
        insert fc;
        
        // Merge
        gm.operation = MERGE_OP;
        gm.getBatchCount();
        gm.sourceGroup = cg.id;
        gm.destGroup = cg2.id;
        
        gm.addGroup();
        
        system.assertEquals( 1, gm.sourceGroups.size() );
        
        gm.IDToRemove = cg.id;
        
        gm.removeGroup();
        
        system.assertEquals( 0, gm.sourceGroups.size() );
        
        gm.addGroup();
        
        Test.startTest();
        gm.launchBatch();
        Test.stopTest();
    }
    
    public static testmethod void runTest2() {
        groupMaster gm = new groupMaster();
        gm.isTest = true;
        
        // Create some new groups
        CollaborationGroup cg = new CollaborationGroup( name = 'groupMaster Test Group', collaborationtype = 'Public' );
        CollaborationGroup cg2 = new CollaborationGroup( name = 'groupMaster Test Group 2', collaborationtype = 'Public' );
        
        insert new CollaborationGroup[] { cg, cg2 };
        
        FeedItem fp = new FeedItem( linkurl = 'http://www.google.com', title = 'google', parentid = cg.id, createdbyid = userinfo.getuserid() );
        insert fp;
        
        //CollaborationGroupFeed cgf = [select id from CollaborationGroupFeed
        //    where feedpostid = :fp.id];
            
        FeedComment fc = new FeedComment( commentbody = 'test comment', feeditemid = fp.id );
        insert fc;
        
        // Copy
        gm.reset();
        gm.copySource = cg.id;
        gm.selectedSource();
        
        system.assertNotEquals( null, gm.newName );     
        
        gm.operation = COPY_OP;
        gm.getBatchCount();
        
        Test.startTest();
        gm.launchBatch();
        Test.stopTest();
    }
    
    public static testmethod void runTest3() {
        groupMaster gm = new groupMaster();
        gm.isTest = true;
        
        // Create some new groups
        CollaborationGroup cg = new CollaborationGroup( name = 'groupMaster Test Group', collaborationtype = 'Public' );
        CollaborationGroup cg2 = new CollaborationGroup( name = 'groupMaster Test Group 2', collaborationtype = 'Public' );
        
        insert new CollaborationGroup[] { cg, cg2 };
        
        // Mass add members
        gm.reset();
        
        gm.sourceGroupID = cg2.id;
        gm.sourceRoleID = [select id from UserRole where portaltype = 'None' limit 1].id;
        gm.sourceProfileID = [select id from Profile where usertype = 'Standard' or usertype = 'CSNOnly' limit 1].id;
        
        gm.whichSelect = 1;
        gm.addGRP();
        gm.whichSelect = 2;
        gm.addGRP();
        gm.whichSelect = 3;
        gm.addGRP();
        
        system.assertEquals( 3, gm.memberSources.size() );
        
        gm.IDToRemove = cg2.id;
        gm.removeGRP();
        
        system.assertEquals( 2, gm.memberSources.size() );
        
        gm.destGroupID = cg2.id;
        
        gm.operation = MEMBER_OP;
        gm.getBatchCount();
        
        Test.startTest();
        gm.launchBatch();   
        Test.stopTest();    
    }
}
