

#include"uniqueID.h"
#include <fstream>
#include <unordered_map>
#include <algorithm>
using namespace std;

struct post{
int user_id;
int64_t post_id;
string post_string;	
	
};

 unordered_multimap<int, post> post_memcached;
 typedef unordered_multimap<int, post>::iterator umit;

#define USER_NUM 10
#define newPost_API_RATIO 90

void newPost(int userID, string post)
{
     int64_t postID =  UploadUniqueId(userID);
	
		
	//TO DO
	//call the text service from grpc call
	//save the post from memcahced or DB
	
	//save to built-in memcached
	struct post _newpost;
	_newpost.user_id=userID;
	_newpost.post_id=postID;
	_newpost.post_string=post;
	
	//post_memcached[userID]=_newpost;
	post_memcached.insert(make_pair(userID, _newpost));

}

void getPostByUser(int userID, vector<string>& posts, int post_num)
{
	//TO DO
	//get post from memcahced or DB
	//get the url original from the url service
	
	//get all post from this user from our memcached
	    pair<umit, umit> it = post_memcached.equal_range(userID);
		umit it1 = it.first;
		pair<int, post> tmp;
		int num=0;
 
    // looping over all values associated with key
    while (it1 != it.second && num < post_num)
    {
        tmp = *it1;
        posts.push_back(tmp.second.post_string);
        it1++;
		num++;
    }
	
}

int main(int argc, char *argv[]) {

	if(argc < 3) {
        printf("You must provide the number of lines and csv file\n");
        exit(0);
    }
	
	  srand (1);
	int num_lines = 0;
	int lines = 0;
	fstream postfile;


	std::string postdir(argv[1]);
	num_lines = atoi(argv[2]);

  
   postfile.open(argv[1],ios::in); 
   if (postfile.is_open()){  
      string tp;
      while(getline(postfile, tp) && lines < num_lines){ 
		if(tp == "")
		  continue;
	  
	  int userID = (rand() % USER_NUM) + 1;
	  if((rand() % 100) < newPost_API_RATIO) {
		  //new post	
		cout << "new post event"<<endl;		  
		cout << "user id: " << userID <<endl;
		cout << "post: " << tp  <<endl<<endl;		  
		newPost(userID, tp);
	  } else {
		cout << "getPostByUser event"<<endl;		  
		cout << "user id: " << userID <<endl;
		
		  vector<string> posts;
		  getPostByUser(userID, posts, 10);
		  cout << "number of posts: " << posts.size() <<endl;
		  for(int i=0; i<posts.size(); ++i)
			cout << "post " << i << " : "<< posts[i]  <<endl;

		cout<<endl;		
	  }
		
		 lines++;
      }
      postfile.close(); 
   }

	return 0;
}