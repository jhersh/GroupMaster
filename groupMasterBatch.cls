// Jonathan Hersh - jhersh@salesforce.com - Feb '11
// batch class for loading members and copying feedposts, feedcomments, feedlikes
//

global class groupMasterBatch implements Database.Batchable<sObject>, Database.Stateful {
    global Set<ID> sourceIDs        { get; set; }
    global ID   destID              { get; set; }
    global string opType            { get; set; }
    global boolean failed           { get; set; }
    global boolean hasGroups        { get; set; }
    global boolean deleteSources    { get; set; }

    global Database.QueryLocator start(Database.BatchableContext BC){    
        failed = false;
        
        string q;
        ID[] roles = new ID[] {};
        ID[] profiles = new ID[] {};
        ID[] groups = new ID[] {};
        
        string rolePref = Schema.Sobjecttype.UserRole.getKeyPrefix();
        string proPref = Schema.Sobjecttype.Profile.getKeyPrefix();
        
        for( ID source : sourceIDs )
            if( (''+ source).substring( 0, 3 ) == proPref )
                profiles.add( source );
            else if( ('' + source).substring( 0, 3 ) == rolePref )
                roles.add( source );
            else
                groups.add( source );
                
        hasGroups = !groups.isEmpty();
        
        if( opType == groupMaster.MEMBER_OP ) {
            if( hasGroups )
                q = 'select memberid '+
                    'from collaborationgroupmember '+
                    'where collaborationgroupid IN :groups';
            else
                q = 'select id '+
                    'from user '+
                    'where isactive = true and ( usertype=\'Standard\' or usertype = \'CSNOnly\' ) '+
                    'and ( '+ 
                    ( !roles.isEmpty() ? 'userroleid IN :roles ' : 'id = null ' ) +
                    ' OR '+
                    ( !profiles.isEmpty() ? 'profileid in :profiles ' : 'id = null ' ) +' ) ';
        } else if( opType == groupMaster.COPY_OP || opType == groupMaster.MERGE_OP )
            q = 'select id, createdbyid, createddate, body, type, relatedrecordid, contentfilename, '+
                'LinkUrl, Title, '+
                '(select createdbyid from FeedLikes), '+
                '(select feeditemid, commentbody, createdbyid, createddate from FeedComments) '+
                'from CollaborationGroupFeed '+
                'where parentid IN :groups and type <> \'TrackedChange\' '+
                'order by id asc';  
                        
        return Database.getQueryLocator(q);
    }

    global void execute(Database.BatchableContext BC, List<sObject> scope){
        ID[] userIDs = new ID[] {};
        
        if( scope == null || scope.isEmpty() )
            return;
        
        // If we're copying members, extract the userids to add
        if( opType == groupMaster.MEMBER_OP ) {
            CollaborationGroupMember[] toAdd = new CollaborationGroupMember[] {};
            
            for( sObject g : scope )
                userIDs.add( ID.valueof( string.valueof( g.get( ( hasGroups ? 'memberid' : 'id' ) ) ) ) );

            if( userIDs.isEmpty() )
                return;
            
            // Which of these users are already in the destination group?
            CollaborationGroupMember[] cgs = [select memberid
                from CollaborationGroupMember
                where collaborationgroupid = :destID
                and memberid IN :userIDs];
            
            Set<ID> curMembers = new Set<ID> ();
            
            for( CollaborationGroupMember cg : cgs )
                curMembers.add( cg.memberid );
                
            for( ID uID : userIDs ) 
                if( !curMembers.contains( uID ) )
                    toAdd.add( new CollaborationGroupMember( collaborationgroupid = destID, memberid = uID ) );
                
            try {
                insert toAdd;
            } catch( Exception e ) {
                failed = true;
            }
        } else if( opType == groupMaster.MERGE_OP || opType == groupMaster.COPY_OP ) {
            // We're copying posts! Do the parent posts first
            FeedItem[] newPosts = new FeedItem[] {};
            FeedComment[] newComments = new FeedComment[] {};
            FeedLike[] newLikes = new FeedLike[] {};
            
            List<FeedComment[]> commentArray = new List<FeedComment[]> ();
            List<FeedLike[]> likeArray = new List<FeedLike[]> ();
        
        // We cannot insert posts by users who are no longer active
        ID[] postCreators = new ID[] {};

        for( sObject s : scope ) {
        postCreators.add( (string) s.get('createdbyid') );
        
        if( s.getSObjects('feedlikes') != null )
                    for( FeedLike fl : s.getSObjects('feedlikes') )
                        postCreators.add( fl.createdbyid );
                
                if( s.getSObjects('feedcomments') != null )
                    for( FeedComment fc : s.getSObjects('feedcomments') )
                        postCreators.add( fc.createdbyid );
        }

        Map<ID, User> activeCreators = new Map<ID, User> ([select id from User
            where isactive=true and ( usertype = 'Standard' or usertype = 'CSNOnly' )
            and id IN :postCreators]);
            
            for( sObject s : scope ) {   
                if( !activeCreators.keySet().contains( (string) s.get('createdbyid') ) )
                    continue;

                FeedItem newPost = new FeedItem();
                
                newPost.body = (string) s.get('body');
                newPost.type = (string) s.get('type');
                newPost.relatedRecordId = (ID) s.get('relatedrecordid');
                newPost.linkURL = (string) s.get('linkurl');
                newPost.title = (string) s.get('title');
                newPost.createddate = (DateTime) s.get('createddate');
                newPost.createdbyid = (ID) s.get('createdbyid');
                newPost.parentid = destID;
                
                if( newPost.type == 'ContentPost' && newPost.relatedRecordID == null )
                    newPost.type = 'TextPost';
                
                if( newPost.body == null ) {
                    if( newPost.type == 'LinkPost' )
                        newPost.body = 'posted a link.';
                    else
                        newPost.body = 'posted a file.';
                }
                
                newPosts.add( newPost );
                
                FeedLike[] likes = new FeedLike[] {};
                FeedComment[] comments = new FeedComment[] {};
                
                if( s.getSObjects('feedlikes') != null ) {
                    for( FeedLike fl : s.getSObjects('feedlikes') ) {
                        if( !activeCreators.keySet().contains( fl.createdbyid ) )
                            continue;

                        FeedLike newFL = new FeedLike();
                        newFL.createdbyid = fl.createdbyid;
                        
                        likes.add( newFL );
                    }
                }
                        
                likeArray.add( likes );
                
                if( s.getSObjects('feedcomments') != null ) {
                    for( FeedComment fc : s.getSObjects('feedcomments') ) {
                        if( !activeCreators.keySet().contains( fc.createdbyid ) )
                            continue;

                        FeedComment newFC = new FeedComment();
                        newFC.createdbyid = fc.createdbyid;
                        newFC.commentbody = fc.commentbody;
                        newFC.createddate = fc.createddate;
                        
                        comments.add( newFC );
                    }
                }
                
                commentArray.add( comments );
            }
                
            try {
                insert newPosts;
            } catch( Exception e ) {
                failed = true;
                return;
            }
            
            ID[] fpIDs = new ID[] {};
      
            // Move comments and likes to their new parents
            for( integer x = 0; x < newPosts.size(); x++ ) {
                for( FeedComment fc : commentArray.get( x ) ) {
                    fc.feeditemid = newPosts.get(x).id;
                    
                    newComments.add( fc );
                }
                
                for( FeedLike fl : likeArray.get( x ) ) {
                    fl.feeditemid = newPosts.get(x).id;
                    
                    newLikes.add( fl );
                }   
            }
                
            try {
                insert newComments;
            } catch( Exception e ) {
                failed = true;
            }
            
            try {
                insert newLikes;
            } catch( Exception e ) {
                failed = true;
            }
        }
    }

    global void finish(Database.BatchableContext BC) {      
        if( opType == groupMaster.MERGE_OP && deleteSources ) {
            CollaborationGroup[] cgs = [select id
                from CollaborationGroup
                where id IN :sourceIDs];
                
            try {
                delete cgs;
            } catch( Exception e ) {
                ApexPages.addMessages( e );
            }
        }    
    }
}